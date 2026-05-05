# t/cases/103_configure_addircserver_log_variable.t
# =============================================================================
# Regression checks for install/configure.pl addIrcServer().
#
# addIrcServer() receives $server_hostname as a local argument. The success log
# must use that local value, not the global interactive $line variable.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_configure_addircserver {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_configure_addircserver {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;
            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_configure_addircserver(
        File::Spec->catfile('.', 'install', 'configure.pl')
    );

    my $body = _extract_sub_body_configure_addircserver($src, 'addIrcServer');

    $assert->ok(
        defined $body,
        'addIrcServer body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\(\$id_network,\s*\$server_hostname\)\s*=\s*\@_/,
        'addIrcServer receives $server_hostname as a local argument'
    );

    $assert->like(
        $body // '',
        qr/\$sth->execute\(\$id_network,\s*\$server_hostname\)/,
        'addIrcServer inserts the local $server_hostname'
    );

    $assert->like(
        $body // '',
        qr/IRC Server \$server_hostname added in SERVERS table with id : \$id_server/,
        'addIrcServer success log uses the local $server_hostname'
    );

    $assert->unlike(
        $body // '',
        qr/IRC Server \$line added in SERVERS table/,
        'addIrcServer success log does not use the global $line variable'
    );
};
