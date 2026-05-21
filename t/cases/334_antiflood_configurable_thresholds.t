# t/cases/334_antiflood_configurable_thresholds.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_334 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_334 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $helpers = _slurp_334(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $sample  = _slurp_334(File::Spec->catfile('.', 'mediabot.sample.conf'));

    my $conf = _sub_334($helpers, '_af_conf_int');
    $assert->ok(defined $conf, '_af_conf_int helper exists');
    $assert->like($conf // '', qr/antiflood\.\$key/, '_af_conf_int reads antiflood.* config keys');
    $assert->like($conf // '', qr/\$default/, '_af_conf_int has defaults');
    $assert->like($conf // '', qr/\$min/, '_af_conf_int clamps minimum values');
    $assert->like($conf // '', qr/\$max/, '_af_conf_int clamps maximum values');

    for my $key (qw(
        CHANFLOOD_WINDOW CHANFLOOD_MAX_COMMANDS CHANFLOOD_SILENCE CHANFLOOD_NOTIFY_COOLDOWN
        NICKFLOOD_WINDOW NICKFLOOD_MAX_COMMANDS NICKFLOOD_NOTIFY_COOLDOWN NICKFLOOD_STATE_TTL
        OUTPUT_PARAMS_CACHE_TTL OUTPUT_STATE_TTL OUTPUT_PARAMS_STATE_TTL
    )) {
        $assert->like($sample, qr/^\Q$key\E=/m, "sample documents antiflood.$key");
    }
};
