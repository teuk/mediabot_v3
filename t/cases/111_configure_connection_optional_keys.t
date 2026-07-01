use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_connection {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_mb378_connection {
    my ($src, $section) = @_;
    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;
    my $wizard = _slurp_mb378_connection(File::Spec->catfile('.', 'install', 'configure.pl'));
    my $main   = _slurp_mb378_connection(File::Spec->catfile('.', 'mediabot.pl'));
    my $core   = _slurp_mb378_connection(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $sample = _slurp_mb378_connection(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $live   = _slurp_mb378_connection(File::Spec->catfile('.', 't', 'live', 'test.conf.tpl'));

    my $runtime = $main . "\n" . $core;
    $assert->like($runtime, qr/get\('connection\.CONN_PASS'\)/,
        'runtime reads connection.CONN_PASS');
    $assert->like($runtime, qr/get\('connection\.CONN_BIND_IP'\)/,
        'runtime reads connection.CONN_BIND_IP');

    $assert->like($wizard, qr/\$set\{'connection\.CONN_PASS'\}/,
        'wizard updates CONN_PASS through the atomic overlay');
    $assert->like($wizard, qr/\$set\{'connection\.CONN_BIND_IP'\}/,
        'wizard updates CONN_BIND_IP through the atomic overlay');
    $assert->like($wizard, qr/IRC server password .*type - to clear/,
        'wizard prompts safely for optional IRC password');
    $assert->like($wizard, qr/Local bind IP .*type - to clear/,
        'wizard prompts for optional bind IP');

    $assert->like(_section_mb378_connection($sample, 'connection') // '', qr/^CONN_PASS=$/m,
        'sample config defines empty CONN_PASS');
    $assert->like(_section_mb378_connection($sample, 'connection') // '', qr/^CONN_BIND_IP=$/m,
        'sample config defines empty CONN_BIND_IP');
    $assert->like(_section_mb378_connection($live, 'connection') // '', qr/^CONN_PASS=$/m,
        'live template defines empty CONN_PASS');
    $assert->like(_section_mb378_connection($live, 'connection') // '', qr/^CONN_BIND_IP=$/m,
        'live template defines empty CONN_BIND_IP');
};
