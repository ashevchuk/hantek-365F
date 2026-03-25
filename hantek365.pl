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

GetOptions(
    'port|p=s'     => \$opt_port,
    'mode|m=s'     => \$opt_mode,
    'relative|r'   => \$opt_relative,
    'verbose|v'    => \$opt_verbose,
    'timestamp|t'  => \$opt_timestamp,
    'csv|c'        => \$opt_csv,
    'interval|i=i' => \$opt_interval,
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
print STDERR "Reading measurements. Press Ctrl+C to stop.\n";

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
                . ($opt_timestamp || $opt_csv ? sprintf('.%03d', $ms) : '');

        if ($opt_csv) {
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
