# MB754 — the quote pack grows from pure readers to reversible mixed commands.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1089 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ManifestV3;
    require Mediabot::Plugin::RuntimeV3;

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/quotes-v3/plugin.json', expected_name => 'quotes-v3');
    $assert->is($manifest->{activation}{default}, 'off',
        'quote migration remains inert by default');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'halloffame,q,quote,quotecount,topquote',
        'the package declares the complete reversible quote surface');
    $assert->ok(exists($manifest->{commands}{q})
            && exists($manifest->{commands}{quote}),
        'mixed read-write quote commands adopt the authorized bridge');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.quotes.read,data.quotes.write,irc.reply,irc.notice',
        'package requests separate read, write and response capabilities');
    for my $command (values %{ $manifest->{commands} }) {
        $assert->is($command->{migration}, 'legacy-public-fallback',
            'every migrated quote command retains explicit rollback');
    }

    my $source = slurp_1089('plugins/quotes-v3/lib/Quotes.pm');
    $assert->ok($source !~ /\b(?:INSERT\s+INTO|UPDATE\s+QUOTES|DELETE\s+FROM)\b/i,
        'plugin source still contains no SQL mutation verb');
    $assert->ok($source !~ /\b(?:DBI|prepare|execute)\b/,
        'plugin source cannot bypass the approved quote facade');

    my $runtime = Mediabot::Plugin::RuntimeV3->new(
        manager => bless({}, 'T1089::Manager'), plugin_dir => 'plugins');
    my @packages = grep { $_->{name} eq 'quotes-v3' }
        $runtime->discover_packages;
    $assert->is(scalar @packages, 1,
        'side-effect-free discovery finds the first-party quote package');
    $assert->is($packages[0]{activation}, 'off',
        'discovery does not activate the quote package');
    $assert->ok(!$runtime->{manager}{registered},
        'discovery performs no registration or lifecycle action');
};
