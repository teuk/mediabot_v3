use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use IPC::Open3;
use Symbol qw(gensym);
use Scalar::Util qw(refaddr);
use Mediabot::External ();
use Mediabot::IRC::TextBudget ();

my @cold = (
    ['TMDB alone', q{use Mediabot::External::TMDB qw(get_tmdb_info mbTMDBSearch_ctx _repair_utf8_mojibake);
        die 'unexpected Claude load' if $INC{'Mediabot/External/Claude.pm'};
        die 'unexpected AI client load' if $INC{'Mediabot/AI/Client.pm'};
        die 'unexpected AI transport load' if $INC{'Mediabot/AI/Transport.pm'};
        die 'missing import' unless defined &get_tmdb_info && defined &mbTMDBSearch_ctx;}],
    ['text budget alone', q{use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);
        die 'unexpected Claude load' if $INC{'Mediabot/External/Claude.pm'};
        die 'unexpected TMDB load' if $INC{'Mediabot/External/TMDB.pm'};
        die 'missing helper' unless _irc_wire_bytes('abc') == 3 && _irc_prefix_for_budget('abc', 2) eq 'ab';}],
    ['legacy imports', q{use Mediabot::External::Claude qw(_repair_utf8_mojibake mbTMDBSearch_ctx get_tmdb_info);
        die 'missing legacy imports' unless defined &get_tmdb_info && defined &mbTMDBSearch_ctx && defined &_repair_utf8_mojibake;}],
);
for my $order (
    [qw(External::TMDB IRC::TextBudget External::Claude External)],
    [qw(External::Claude External::TMDB External IRC::TextBudget)],
    [qw(IRC::TextBudget External External::TMDB External::Claude)],
) {
    push @cold, [join('/', @$order), join('', map {"require Mediabot::$_;\n"} @$order)
        . q{die 'missing facade' unless defined &Mediabot::External::get_tmdb_info && defined &Mediabot::External::mbTMDBSearch_ctx;}];
}
for my $case (@cold) {
    my ($label, $code) = @$case;
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code . q{print 'loaded';});
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, "$label: fresh interpreter loads successfully");
    is($stdout, 'loaded', "$label: all import checks complete");
    is($stderr, '', "$label: no circular-load or redefinition diagnostics");
}
for my $name (qw(_repair_utf8_mojibake mbTMDBSearch_ctx get_tmdb_info _tmdb_first_nonempty)) {
    no strict 'refs';
    my $owner = \&{"Mediabot::External::TMDB::$name"};
    is(refaddr(\&{"Mediabot::External::Claude::$name"}), refaddr($owner), "$name: legacy and owner use one implementation");
    next if $name eq '_tmdb_first_nonempty';
    is(refaddr(\&{"Mediabot::External::$name"}), refaddr($owner), "$name: facade imports the implementation owner");
}
for my $name (qw(_irc_wire_bytes _irc_prefix_for_budget)) {
    no strict 'refs';
    my $owner = \&{"Mediabot::IRC::TextBudget::$name"};
    for my $caller (qw(Claude TMDB)) {
        is(refaddr(\&{"Mediabot::External::${caller}::$name"}), refaddr($owner), "$caller: byte helper has a single shared owner");
    }
}
for my $row ([undef, 0], ['', 0], ['ascii', 5], ['été', 5], [encode('UTF-8','été'), 5], ['🎬', 4]) {
    for my $bytes (\&Mediabot::IRC::TextBudget::_irc_wire_bytes,
        \&Mediabot::External::Claude::_irc_wire_bytes, \&Mediabot::External::TMDB::_irc_wire_bytes) {
        is($bytes->($row->[0]), $row->[1], 'shared byte accounting preserves character and already-encoded input behavior');
    }
}
for my $budget (1, 2, 3, 4, 5, 16, 40) {
    my $text = '🎬 été movie';
    my $prefix = Mediabot::IRC::TextBudget::_irc_prefix_for_budget($text, $budget);
    cmp_ok(length(encode('UTF-8', $prefix)), '<=', $budget, 'shared prefix fits small and normal byte budgets');
    is(index($text, $prefix), 0, 'shared prefix remains a complete-character prefix of the source');
}
done_testing;
