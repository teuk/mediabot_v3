package Mediabot::Convert;
# ===========================================================================
# Mediabot::Convert — offline unit conversion (mb479).
#
# Pure, dependency-free unit conversion across a few common families:
#   length, mass, temperature, volume, speed, data (bytes).
#
# Public API:
#   my ($ok, $result_or_error) = Mediabot::Convert::convert($value, $from, $to);
#     - $ok == 1  : $result_or_error is a formatted string "X unit = Y unit"
#     - $ok == 0  : $result_or_error is a short error message
#
# Design:
#   - Linear units (length/mass/volume/speed/data) convert through a base unit
#     via a factor table; from/to must be in the SAME family.
#   - Temperature is special-cased (affine, not linear) with explicit formulas.
#   - Unit names are case-insensitive and accept common aliases/symbols.
#   - No eval, no external calls, no I/O. Safe to call on user input.
# ===========================================================================

use strict;
use warnings;

# --- alias table: normalise many spellings/symbols to a canonical unit key ---
my %ALIAS = (
    # length
    'mm' => 'mm', 'millimeter' => 'mm', 'millimetre' => 'mm', 'millimeters' => 'mm', 'millimetres' => 'mm',
    'cm' => 'cm', 'centimeter' => 'cm', 'centimetre' => 'cm', 'centimeters' => 'cm', 'centimetres' => 'cm',
    'm'  => 'm',  'meter' => 'm', 'metre' => 'm', 'meters' => 'm', 'metres' => 'm',
    'km' => 'km', 'kilometer' => 'km', 'kilometre' => 'km', 'kilometers' => 'km', 'kilometres' => 'km',
    'in' => 'in', 'inch' => 'in', 'inches' => 'in', '"' => 'in',
    'ft' => 'ft', 'foot' => 'ft', 'feet' => 'ft', "'" => 'ft',
    'yd' => 'yd', 'yard' => 'yd', 'yards' => 'yd',
    'mi' => 'mi', 'mile' => 'mi', 'miles' => 'mi',
    'nmi'=> 'nmi','nauticalmile' => 'nmi', 'nauticalmiles' => 'nmi',
    # mass
    'mg' => 'mg', 'milligram' => 'mg', 'milligrams' => 'mg',
    'g'  => 'g',  'gram' => 'g', 'grams' => 'g', 'gramme' => 'g', 'grammes' => 'g',
    'kg' => 'kg', 'kilogram' => 'kg', 'kilograms' => 'kg', 'kilo' => 'kg', 'kilos' => 'kg',
    't'  => 't',  'tonne' => 't', 'tonnes' => 't', 'metricton' => 't',
    'oz' => 'oz', 'ounce' => 'oz', 'ounces' => 'oz',
    'lb' => 'lb', 'lbs' => 'lb', 'pound' => 'lb', 'pounds' => 'lb',
    'st' => 'st', 'stone' => 'st', 'stones' => 'st',
    # temperature
    'c' => 'c', 'celsius' => 'c', 'centigrade' => 'c', '°c' => 'c',
    'f' => 'f', 'fahrenheit' => 'f', '°f' => 'f',
    'k' => 'k', 'kelvin' => 'k',
    # volume
    'ml' => 'ml', 'milliliter' => 'ml', 'millilitre' => 'ml', 'milliliters' => 'ml', 'millilitres' => 'ml',
    'l'  => 'l',  'liter' => 'l', 'litre' => 'l', 'liters' => 'l', 'litres' => 'l',
    'gal'=> 'gal','gallon' => 'gal', 'gallons' => 'gal',
    'qt' => 'qt', 'quart' => 'qt', 'quarts' => 'qt',
    'pt' => 'pt', 'pint' => 'pt', 'pints' => 'pt',
    'cup'=> 'cup','cups' => 'cup',
    'floz'=> 'floz', 'fluidounce' => 'floz', 'fluidounces' => 'floz',
    # speed
    'kmh' => 'kmh', 'km/h' => 'kmh', 'kph' => 'kmh',
    'mph' => 'mph', 'mi/h' => 'mph',
    'ms'  => 'ms', 'm/s' => 'ms',
    'kn'  => 'kn', 'knot' => 'kn', 'knots' => 'kn',
    # data (decimal + binary)
    'b' => 'b', 'byte' => 'b', 'bytes' => 'b',
    'kb'=> 'kb','kilobyte' => 'kb', 'kilobytes' => 'kb',
    'mb'=> 'mb','megabyte' => 'mb', 'megabytes' => 'mb',
    'gb'=> 'gb','gigabyte' => 'gb', 'gigabytes' => 'gb',
    'tb'=> 'tb','terabyte' => 'tb', 'terabytes' => 'tb',
    'kib'=> 'kib', 'mib' => 'mib', 'gib' => 'gib', 'tib' => 'tib',
);

# --- family + base-unit factor tables (value_in_base = value * factor) ---
my %FAMILY = (
    length => {
        base => 'm',
        f => { mm=>0.001, cm=>0.01, m=>1, km=>1000,
               in=>0.0254, ft=>0.3048, yd=>0.9144, mi=>1609.344, nmi=>1852 },
    },
    mass => {
        base => 'kg',
        f => { mg=>1e-6, g=>0.001, kg=>1, t=>1000,
               oz=>0.028349523125, lb=>0.45359237, st=>6.35029318 },
    },
    volume => {
        base => 'l',
        f => { ml=>0.001, l=>1, gal=>3.785411784, qt=>0.946352946,
               pt=>0.473176473, cup=>0.2365882365, floz=>0.0295735295625 },
    },
    speed => {
        base => 'ms',
        f => { ms=>1, kmh=>0.277777777778, mph=>0.44704, kn=>0.514444444444 },
    },
    data => {
        base => 'b',
        f => { b=>1, kb=>1e3, mb=>1e6, gb=>1e9, tb=>1e12,
               kib=>1024, mib=>1048576, gib=>1073741824, tib=>1099511627776 },
    },
);

# reverse index: canonical unit -> family
my %UNIT_FAMILY;
for my $fam (keys %FAMILY) {
    $UNIT_FAMILY{$_} = $fam for keys %{ $FAMILY{$fam}{f} };
}
my %TEMP = map { $_ => 1 } qw(c f k);

# pretty display label for a canonical unit
my %LABEL = (
    mm=>'mm', cm=>'cm', m=>'m', km=>'km', in=>'in', ft=>'ft', yd=>'yd', mi=>'mi', nmi=>'nmi',
    mg=>'mg', g=>'g', kg=>'kg', t=>'t', oz=>'oz', lb=>'lb', st=>'st',
    c=>'°C', f=>'°F', k=>'K',
    ml=>'ml', l=>'L', gal=>'gal', qt=>'qt', pt=>'pt', cup=>'cup', floz=>'fl oz',
    kmh=>'km/h', mph=>'mph', ms=>'m/s', kn=>'kn',
    b=>'B', kb=>'kB', mb=>'MB', gb=>'GB', tb=>'TB', kib=>'KiB', mib=>'MiB', gib=>'GiB', tib=>'TiB',
);

sub _canon {
    my ($u) = @_;
    return undef unless defined $u;
    $u = lc $u;
    $u =~ s/\s+//g;
    return $ALIAS{$u};
}

sub _fmt {
    my ($n) = @_;
    # up to 6 significant-ish digits, trim trailing zeros
    my $s = sprintf('%.6f', $n);
    $s =~ s/0+$// if $s =~ /\./;
    $s =~ s/\.$//;
    # very large/small -> scientific
    if (abs($n) != 0 && (abs($n) >= 1e12 || abs($n) < 1e-6)) {
        $s = sprintf('%.4g', $n);
    }
    return $s;
}

# temperature conversion via Celsius as pivot
sub _temp_to_c { my ($v,$u)=@_; return $u eq 'c' ? $v : $u eq 'f' ? (($v-32)*5/9) : ($v-273.15); }
sub _temp_from_c { my ($v,$u)=@_; return $u eq 'c' ? $v : $u eq 'f' ? ($v*9/5+32) : ($v+273.15); }

# convert($value, $from, $to) -> ($ok, $string_or_error)
sub convert {
    my ($value, $from_raw, $to_raw) = @_;

    return (0, "value must be a number") unless defined $value && $value =~ /^[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?$/;
    my $from = _canon($from_raw);
    my $to   = _canon($to_raw);
    return (0, "unknown unit '" . (defined $from_raw ? $from_raw : '') . "'") unless defined $from;
    return (0, "unknown unit '" . (defined $to_raw   ? $to_raw   : '') . "'") unless defined $to;

    # temperature family
    if ($TEMP{$from} || $TEMP{$to}) {
        unless ($TEMP{$from} && $TEMP{$to}) {
            return (0, "cannot convert between temperature and non-temperature units");
        }
        my $c   = _temp_to_c($value + 0, $from);
        my $out = _temp_from_c($c, $to);
        return (1, _fmt($value) . " $LABEL{$from} = " . _fmt($out) . " $LABEL{$to}");
    }

    my $ff = $UNIT_FAMILY{$from};
    my $tf = $UNIT_FAMILY{$to};
    return (0, "unsupported unit") unless defined $ff && defined $tf;
    return (0, "cannot convert $LABEL{$from} to $LABEL{$to} (different families)") unless $ff eq $tf;

    my $base = ($value + 0) * $FAMILY{$ff}{f}{$from};
    my $out  = $base / $FAMILY{$tf}{f}{$to};
    return (1, _fmt($value) . " $LABEL{$from} = " . _fmt($out) . " $LABEL{$to}");
}

1;
