#!/usr/bin/env perl

#
# hantek365.pl — Command-line utility for the Hantek 365C/D/E/F multimeter
#
# The device connects over USB-dongle and presents itself
# as a standard CDC-ACM serial port (/dev/ttyACM0 or similar)
# no proprietary drivers needed:
# 0451:16aa Texas Instruments, Inc. TI CC2540 USB CDC
#
# If the device cannot be opened, add yourself to the dialout group:
#   sudo usermod -aG dialout $USER  (re-login afterwards)
#
# Usage:
#   ./hantek365.pl -m VDC -t        # DC voltage with timestamp
#   ./hantek365.pl -m ohm -c        # resistance output as CSV
#   ./hantek365.pl -p /dev/ttyACM1 -m temp -v   # different port, debug
#

use strict;
use warnings;

use POSIX qw(:termios_h strftime);
use Fcntl qw(O_RDWR O_NOCTTY);
use Getopt::Long qw(:config no_ignore_case bundling);
use Time::HiRes qw(time usleep);

# ─── Protocol constants ─────────────────────────────────────────────────────
use constant CMD_MODE   => 0x03;          # command type byte for mode selection
use constant CMD_GET    => "\x01\x0f";    # request current reading
use constant ACK_MODE   => 0xdd;          # mode change acknowledgement
use constant PKT_OK     => 0xA0;          # valid measurement packet header
use constant PKT_NODATA => 0xAA;          # no data available (keep-alive)
use constant PKT_LEN    => 15;            # valid measurement packet length

# ─── Measurement modes (keys lowercase for case-insensitive lookup) ──────────
my %MODES = (
    # DC voltage
    'vdc'     => 0xa0,  '60mvdc'  => 0xa1,  '600mvdc' => 0xa2,
    '6vdc'    => 0xa3,  '60vdc'   => 0xa4,  '600vdc'  => 0xa5,  '800vdc'  => 0xa6,
    # AC voltage
    'vac'     => 0xb0,  '60mvac'  => 0xb1,  '600mvac' => 0xb2,
    '6vac'    => 0xb3,  '60vac'   => 0xb4,  '600vac'  => 0xb5,
    # DC current
    'madc'    => 0xc0,  '60madc'  => 0xc1,  '600madc' => 0xc2,  'adc'     => 0xc3,
    # AC current
    'maac'    => 0xd0,  '60maac'  => 0xd1,  '600maac' => 0xd2,  'aac'     => 0xd3,
    # Resistance
    'ohm'     => 0xe0,  '600ohm'  => 0xe1,  '6kohm'   => 0xe2,
    '60kohm'  => 0xe3,  '600kohm' => 0xe4,  '6mohm'   => 0xe5,  '60mohm'  => 0xe6,
    # Special modes
    'diode'   => 0xf0,  # diode test
    'cap'     => 0xf1,  # capacitance
    'cont'    => 0xf2,  # continuity test
    'temp'    => 0xf5,  # temperature (Celsius)
    'tempc'   => 0xf5,  # temperature (Celsius, explicit alias)
    'tempf'   => 0xf6,  # temperature (Fahrenheit)
);

# ─── Command-line argument parsing ──────────────────────────────────────────
my $opt_port      = '/dev/ttyACM0';
my $opt_mode      = '';
my $opt_relative  = 0;
my $opt_verbose   = 0;
my $opt_timestamp = 0;
my $opt_csv       = 0;
my $opt_interval  = 0;    # extra delay between readings (ms)
my $opt_tui       = 0;    # TUI graph mode

GetOptions(
    'port|p=s'     => \$opt_port,
    'mode|m=s'     => \$opt_mode,
    'relative|r'   => \$opt_relative,
    'verbose|v'    => \$opt_verbose,
    'timestamp|t'  => \$opt_timestamp,
    'csv|c'        => \$opt_csv,
    'interval|i=i' => \$opt_interval,
    'tui|g'        => \$opt_tui,
    'help|h'       => \&usage,
) or die "Try '$0 --help' for help.\n";

sub usage {
    (my $prog = $0) =~ s{.*/}{};
    print <<"USAGE";
Usage: $prog [options]

Options:
  -p, --port PORT       Serial port (default: /dev/ttyACM0)
  -m, --mode MODE       Set measurement mode
  -r, --relative        Enable relative measurement mode (REL)
  -v, --verbose         Debug output: raw packet bytes
  -t, --timestamp       Prefix each reading with a timestamp
  -c, --csv             CSV output (timestamp,value,prefix,unit,flags)
  -i, --interval MS     Minimum interval between readings in ms (0 = as fast as possible)
  -g, --tui             TUI graph mode: scrolling bar chart in the terminal
  -h, --help            Show this help

Available modes (case-insensitive):
  DC Voltage    : VDC  60mVDC  600mVDC  6VDC  60VDC  600VDC  800VDC
  AC Voltage    : VAC  60mVAC  600mVAC  6VAC  60VAC  600VAC
  DC Current    : mADC 60mADC  600mADC  ADC
  AC Current    : mAAC 60mAAC  600mAAC  AAC
  Resistance    : ohm  600ohm  6kohm    60kohm  600kohm  6Mohm  60Mohm
  Special       : diode  cap  cont  temp  tempc  tempf

Examples:
  $prog -m VDC -t                 # DC voltage with timestamp
  $prog -m ohm -c > data.csv      # Resistance in CSV-output
  $prog -m temp --interval 1000   # Temperature once per second
  $prog -p /dev/ttyACM1 -m VAC -v # Use different port with verbose output
  $prog -m VDC --tui              # DC voltage as scrolling graph

USAGE
    exit 0;
}

# ─── Resolve mode code ───────────────────────────────────────────────────────
my $selected_mode = 0;
if ($opt_mode) {
    $selected_mode = $MODES{lc($opt_mode)};
    unless (defined $selected_mode) {
        die "Unknown mode '$opt_mode'.\n"
          . "Run '$0 --help' for the list of available modes.\n";
    }
}

# ─── Open serial port ────────────────────────────────────────────────────────
sysopen(my $fh, $opt_port, O_RDWR | O_NOCTTY)
    or die "Cannot open '$opt_port': $!\n"
         . "Make sure the device is connected and you are in the 'dialout' group:\n"
         . "  sudo usermod -aG dialout \$USER\n";

# Configure port in raw mode via POSIX termios.
# For CDC-ACM devices the baud rate does not matter — data travels over USB —
# but raw mode is required for correct binary data transfer.
{
    my $t = POSIX::Termios->new();
    $t->getattr(fileno($fh));
    $t->setiflag(0);                        # no input processing
    $t->setoflag(0);                        # no output processing
    $t->setlflag(0);                        # canonical mode off (raw)
    $t->setcflag(CS8 | CREAD | CLOCAL);    # 8-bit, enable read, ignore DCD
    $t->setcc(VMIN,  0);   # non-blocking read (return immediately, even 0 bytes)
    $t->setcc(VTIME, 10);  # timeout: 10 × 0.1 s = 1 second
    $t->setattr(fileno($fh), TCSANOW);
}

# Enable auto-flush for STDOUT
$| = 1;

# ─── Signal handling ─────────────────────────────────────────────────────────
my $running = 1;
$SIG{INT}  = sub { print STDERR "\nSIGINT received, stopping...\n"; $running = 0 };
$SIG{TERM} = sub { print STDERR "\nSIGTERM received, stopping...\n"; $running = 0 };

# ─── TUI mode ────────────────────────────────────────────────────────────────
my @BLOCKS = (
    ' ',
    "\xe2\x96\x81",  # ▁ lower one-eighth block
    "\xe2\x96\x82",  # ▂
    "\xe2\x96\x83",  # ▃
    "\xe2\x96\x84",  # ▄
    "\xe2\x96\x85",  # ▅
    "\xe2\x96\x86",  # ▆
    "\xe2\x96\x87",  # ▇
    "\xe2\x96\x88",  # █ full block
);
use constant TUI_LABEL_W => 10;  # columns reserved for y-axis labels + │ separator

my @tui_buf         = ();
my $tui_min         = undef;
my $tui_max         = undef;
my $tui_initialized = 0;

# Get terminal dimensions via TIOCGWINSZ ioctl (Linux).
sub get_term_size {
    my $ws = "\0" x 8;
    if (ioctl(STDOUT, 0x5413, $ws)) {
        my ($rows, $cols) = unpack('S2', $ws);
        return ($cols > 4 ? $cols : 80, $rows > 4 ? $rows : 24);
    }
    return (80, 24);
}

sub tui_render {
    my ($p, $ts) = @_;

    # Extract numeric value in base units (apply prefix multiplier so that
    # switching ranges, e.g. V → mV, does not distort the graph scale).
    (my $numstr = $p->{value}) =~ s/[^0-9.]//g;
    return unless length($numstr);

    my %PFX_MULT = (
        "\xc2\xb5" => 1e-6,   # µ (micro)
        'n'        => 1e-9,   # nano
        'm'        => 1e-3,   # milli
        ''         => 1,
        'k'        => 1e3,    # kilo
        'M'        => 1e6,    # Mega
    );
    my $mult = $PFX_MULT{$p->{prefix}} // 1;

    my $val = ($numstr + 0) * $mult;
    $val = -$val if $p->{sign} eq '-';

    push @tui_buf, $val;
    $tui_min = $val if !defined $tui_min || $val < $tui_min;
    $tui_max = $val if !defined $tui_max || $val > $tui_max;

    my ($cols, $rows) = get_term_size();
    my $bar_w = $cols - TUI_LABEL_W;
    $bar_w = 1 if $bar_w < 1;

    # Keep rolling buffer at most $bar_w entries
    splice @tui_buf, 0, @tui_buf - $bar_w if @tui_buf > $bar_w;

    my $graph_rows = $rows - 4;   # 3 header lines + 1 x-axis line
    $graph_rows = 2 if $graph_rows < 2;

    # First call: clear screen and hide cursor
    if (!$tui_initialized) {
        print "\033[2J\033[?25l";
        $tui_initialized = 1;
    }
    print "\033[H";   # move cursor to top-left

    # ── Line 1: current reading ────────────────────────────────────────────────
    my $reading = sprintf '%s%s %s%s  %s',
        $p->{sign}, $p->{value}, $p->{prefix}, $p->{unit}, $p->{flags};
    printf "\033[1m  %-*s\033[0m\n", $cols - 2, $reading;

    # ── Line 2: timestamp + min/max stats (values in base units) ─────────────
    printf "\033[2m  %s   Min:%-10s Max:%-10s %s\033[0m\n",
        $ts,
        sprintf('%.5g', $tui_min),
        sprintf('%.5g', $tui_max),
        $p->{unit};

    # ── Line 3: separator ──────────────────────────────────────────────────────
    print "\033[2m" . ("\xe2\x94\x80" x $cols) . "\033[0m\n";  # ─ × cols

    # ── Graph ──────────────────────────────────────────────────────────────────
    my $range = $tui_max - $tui_min;

    # canvas[row][col] — one character per terminal cell
    my @canvas = map { [(' ') x $bar_w] } 0 .. $graph_rows - 1;

    my $n = scalar @tui_buf;
    for my $i (0 .. $n - 1) {
        my $col = $bar_w - $n + $i;
        next if $col < 0;

        my $frac = $range == 0
            ? 0.5
            : ($tui_buf[$i] - $tui_min) / $range;
        $frac = 0 if $frac < 0;
        $frac = 1 if $frac > 1;

        # Total fill in eighths of a row, then split into full rows + partial
        my $total8 = int($frac * $graph_rows * 8 + 0.5);
        my $nfull  = int($total8 / 8);
        my $npart  = $total8 % 8;

        # Fill full rows from bottom up
        for my $r (1 .. $nfull) {
            my $row = $graph_rows - $r;
            $canvas[$row][$col] = $BLOCKS[8] if $row >= 0;
        }
        # Partial block one row above the full ones
        if ($npart && $nfull < $graph_rows) {
            my $row = $graph_rows - 1 - $nfull;
            $canvas[$row][$col] = $BLOCKS[$npart] if $row >= 0;
        }
    }

    # Print graph rows with y-axis labels on the left
    for my $r (0 .. $graph_rows - 1) {
        my $label = '';
        if    ($r == 0)                    { $label = sprintf '%.4g', $tui_max }
        elsif ($r == $graph_rows - 1)      { $label = sprintf '%.4g', $tui_min }
        elsif ($r == int($graph_rows / 2)) { $label = sprintf '%.4g', ($tui_min + $tui_max) / 2 }
        printf "\033[2m%9s\xe2\x94\x82\033[0m%s\n",  # │
            $label, join('', @{$canvas[$r]});
    }

    # X-axis line
    printf "\033[2m%9s\xe2\x94\x94%s\033[0m",        # └ + ─ × bar_w
        '', "\xe2\x94\x80" x $bar_w;
}

END { print "\033[?25h\n" if $opt_tui }  # restore cursor on exit

# ─── Low-level I/O ───────────────────────────────────────────────────────────

# Write bytes to the device.
sub dev_write {
    my ($bytes) = @_;
    my $n = syswrite($fh, $bytes);
    die "Device write error: $!\n"
        unless defined $n && $n == length($bytes);
}

# Read up to $maxlen bytes with a $timeout_sec second timeout.
# Returns the data read (may be shorter than $maxlen on timeout).
sub dev_read {
    my ($maxlen, $timeout_sec) = @_;
    $timeout_sec //= 1.0;

    my $buf      = '';
    my $deadline = time() + $timeout_sec;
    my $rin      = '';
    vec($rin, fileno($fh), 1) = 1;

    while (length($buf) < $maxlen) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;

        my $nfound = select(my $rout = $rin, undef, undef, $remaining);
        last unless $nfound > 0;

        my $chunk;
        my $n = sysread($fh, $chunk, $maxlen - length($buf));
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    return $buf;
}

# ─── Set measurement mode ─────────────────────────────────────────────────────
# Protocol: for modes 0xA0–0xE6 cycle through sub-ranges from 0 to the target,
# sending [0x03, (base | i)] and expecting 0xdd for each step.
# For special modes 0xF0–0xF6 send directly.
if ($selected_mode) {
    printf STDERR "Setting mode: %s (0x%02x)\n", uc($opt_mode), $selected_mode;

    my $is_special = ($selected_mode & 0xF0) == 0xF0;
    my $mode_set   = 0;

    for my $i (0 .. 16) {
        my $current = $is_special
            ? $selected_mode
            : (($selected_mode & 0xF0) | ($i & 0x0F));

        printf STDERR "  -> sending 0x%02x\n", $current if $opt_verbose;

        dev_write(chr(CMD_MODE) . chr($current));
        my $resp = dev_read(1, 0.5);

        if (length($resp) == 1 && ord($resp) == ACK_MODE) {
            usleep(50_000);  # 50 ms pause as in the original C code
            if ($current == $selected_mode) {
                print STDERR "Mode set.\n";
                $mode_set = 1;
                last;
            }
        } else {
            my $got = length($resp)
                ? sprintf('0x%02x', ord($resp))
                : 'timeout';
            warn "Warning: unexpected device response to mode change: $got\n";
            last;
        }

        last if $is_special;
    }

    warn "Warning: mode may not have been set correctly.\n"
        unless $mode_set;
}

# ─── Relative measurement mode (REL) ────────────────────────────────────────
if ($opt_relative) {
    print STDERR "Enabling relative measurement mode...\n";
    dev_write(chr(CMD_MODE) . chr(0xf3));
    my $resp = dev_read(1, 0.5);
    if (length($resp) == 1 && ord($resp) == ACK_MODE) {
        print STDERR "REL mode enabled.\n";
    } else {
        warn "Failed to enable REL mode.\n";
    }
}

# ─── Measurement packet parsing ───────────────────────────────────────────────
#
# 15-byte packet format:
#   [0]  = 0xA0  — packet start marker
#   [1]  = sign  — bit2=minus, bit1=plus
#   [2..5] = 4 ASCII digit characters ('0'..'9')
#   [6]  = reserved
#   [7]  = decimal point position (ASCII mask: 2^i → point after i-th digit)
#   [8]  = flags: bit3=AC, bit4=DC, bit5=AUTO, bit2=REL
#   [9]  = nano flag (bit1=nano)
#   [10] = multiplier: 0x80=µ, 0x40=m, 0x20=k, 0x10=M, 0x08=beep
#   [11] = units: 0x01=°F, 0x02=°C, 0x04=F, 0x20=Ω, 0x40=A, 0x80=V
#
sub parse_packet {
    my ($pkt) = @_;
    return undef unless length($pkt) == PKT_LEN;

    my @b = unpack('C*', $pkt);
    return undef unless $b[0] == PKT_OK;

    my $sign  = $b[1];
    my @dig   = map { chr($b[$_ + 2]) } 0 .. 3;
    my $dpos  = $b[7];
    my $acdc  = $b[8];
    my $nano  = $b[9];
    my $mult  = $b[10];
    my $units = $b[11];

    # Build numeric string with decimal point.
    # dpos encodes the position as a power of two:
    #   dpos=0x31 (val=1=2^0) → point after digit 0: X.XXX
    #   dpos=0x32 (val=2=2^1) → point after digit 1: XX.XX
    #   dpos=0x34 (val=4=2^2) → point after digit 2: XXX.X
    #   dpos=0x38 (val=8=2^3) → point after digit 3: XXXX.
    my $dval     = $dpos - 0x30;
    my $value_str = '';
    for my $i (0 .. 3) {
        $value_str .= $dig[$i];
        $value_str .= '.' if $dval && ($dval >> $i) == 1;
    }

    # Sign
    my $sign_str = ($sign & 0x04) ? '-'
                 : ($sign & 0x02) ? '+'
                 :                  ' ';

    # Multiplier prefix
    my $beep = 0;
    my $pfx;
    if    ($mult == 0x80) { $pfx = "\xc2\xb5" }  # µ (micro)
    elsif ($mult == 0x40) { $pfx = 'm'         }  # milli
    elsif ($mult == 0x20) { $pfx = 'k'         }  # kilo
    elsif ($mult == 0x10) { $pfx = 'M'         }  # Mega
    elsif ($mult == 0x08) { $pfx = ''; $beep=1 }  # continuity beep
    elsif ($nano & 0x02)  { $pfx = 'n'         }  # nano
    else                  { $pfx = ''           }

    # Units of measurement (UTF-8)
    my $unit;
    if    ($units == 0x01) { $unit = "\xc2\xb0F"    }   # °F
    elsif ($units == 0x02) { $unit = "\xc2\xb0C"    }   # °C
    elsif ($units == 0x04) { $unit = 'F'             }   # Farad
    elsif ($units == 0x20) { $unit = "\xe2\x84\xa6" }   # Ω
    elsif ($units == 0x40) { $unit = 'A'             }   # Ampere
    elsif ($units == 0x80) { $unit = 'V'             }   # Volt
    else                   { $unit = sprintf('%02xh', $units) }

    $unit .= "\xe2\x99\xab" if $beep;  # ♫ continuity beep

    # Mode flags
    my @flags;
    push @flags, 'AC'   if $acdc & 0x08;
    push @flags, 'DC'   if $acdc & 0x10;
    push @flags, 'AUTO' if $acdc & 0x20;
    push @flags, 'MANU' unless $acdc & 0x20;
    push @flags, 'REL'  if $acdc & 0x04;
    my $flags_str = join(' ', @flags);

    return {
        sign      => $sign_str,
        value     => $value_str,
        prefix    => $pfx,
        unit      => $unit,
        flags     => $flags_str,
    };
}

# ─── CSV header ──────────────────────────────────────────────────────────────
if ($opt_csv) {
    print "timestamp,value,prefix,unit,flags\n";
}

# ─── Main reading loop ───────────────────────────────────────────────────────
print STDERR "Reading measurements. Press Ctrl+C to stop.\n" unless $opt_tui;

my $next_read = time();

while ($running) {

    # Wait until the next scheduled read (if --interval is set)
    if ($opt_interval > 0) {
        my $wait = $next_read - time();
        usleep(int($wait * 1_000_000)) if $wait > 0;
        $next_read += $opt_interval / 1000.0;
    }

    # Send measurement request
    dev_write(CMD_GET);

    # Read header byte to determine packet type
    my $hdr = dev_read(1, 1.0);
    if (length($hdr) == 0) {
        warn "Timeout: device not responding.\n" if $opt_verbose;
        usleep(200_000);
        next;
    }

    my $first = ord($hdr);

    if ($first == PKT_NODATA) {
        # Device not ready, wait 200 ms
        usleep(200_000);
        next;
    }

    if ($first == PKT_OK) {
        # Read remaining 14 bytes of packet
        my $rest = dev_read(PKT_LEN - 1, 1.0);
        my $pkt  = $hdr . $rest;

        if ($opt_verbose) {
            printf STDERR "RAW [%d]: %s\n",
                length($pkt),
                join(' ', map { sprintf '%02x', $_ } unpack('C*', $pkt));
        }

        unless (length($pkt) == PKT_LEN) {
            warn sprintf "Incomplete packet (%d/%d bytes).\n",
                length($pkt), PKT_LEN if $opt_verbose;
            next;
        }

        my $p = parse_packet($pkt);
        unless ($p) {
            warn "Failed to parse packet.\n" if $opt_verbose;
            next;
        }

        my $now = time();
        my $ms  = int(($now - int($now)) * 1000);
        my $ts  = strftime('%Y-%m-%d %H:%M:%S', localtime($now))
                . ($opt_timestamp || $opt_csv || $opt_tui ? sprintf('.%03d', $ms) : '');

        if ($opt_tui) {
            tui_render($p, $ts);
        } elsif ($opt_csv) {
            printf "%s,%s%s,%s,%s,%s\n",
                $ts,
                $p->{sign} eq ' ' ? '' : $p->{sign},
                $p->{value},
                $p->{prefix},
                $p->{unit},
                $p->{flags};
        } else {
            my $reading = sprintf "%s%s %s%s  %s",
                $p->{sign}, $p->{value},
                $p->{prefix}, $p->{unit},
                $p->{flags};
            if ($opt_timestamp) {
                print "$ts | $reading\n";
            } else {
                print "$reading\n";
            }
        }

    } else {
        printf STDERR "Unknown packet: 0x%02x\n", $first if $opt_verbose;
        usleep(200_000);
    }
}

close($fh);
print STDERR "Done.\n";
