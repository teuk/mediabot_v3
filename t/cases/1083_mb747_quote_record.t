# MB747 — immutable detached quote records.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::QuoteRecordV3;

    # MB1203: conversion must preserve database identifiers and counters exactly.
    for my $field (qw(id author_id hits)) {
        for my $bad ('18446744073709551616', '18446744073709551617', '9' x 400) {
            my $ok = eval {
                Mediabot::Plugin::QuoteRecordV3->new(id => 1, text => 'valid', $field => $bad);
                1;
            };
            $assert->ok(!$ok, "mb1203: $field rejects overflowing integer");
        }
        for my $value ('00042', '2147483647') {
            my $record = Mediabot::Plugin::QuoteRecordV3->new(id => 1, text => 'valid', $field => $value);
            $assert->is('' . $record->$field(), '' . (0 + $value),
                "mb1203: $field retains exact valid integer");
        }
    }
    for my $zero ('0', '00', '000') {
        my $ok = eval { Mediabot::Plugin::QuoteRecordV3->new(id => $zero, text => 'valid'); 1 };
        $assert->ok(!$ok, 'mb1203: every spelling of zero id is rejected');
        my $record = Mediabot::Plugin::QuoteRecordV3->new(id => 1, text => 'valid',
            author_id => $zero, hits => $zero);
        $assert->is($record->author_id, 0, 'mb1203: zero author remains valid');
        $assert->is($record->hits, 0, 'mb1203: zero hits remain valid');
    }
    require Config;
    if ($Config::Config{uvsize} >= 8) {
        my $record = Mediabot::Plugin::QuoteRecordV3->new(id => '18446744073709551615', text => 'valid');
        $assert->is('' . $record->id, '18446744073709551615',
            'mb1203: native unsigned maximum remains exact');
    }


    my $record = Mediabot::Plugin::QuoteRecordV3->new(
        id => 42, text => "hello\nworld", author => 'Tangy', author_id => 7,
        created_at => '2026-09-19 20:00:00', hits => 3,
    );
    $assert->is($record->id, 42, 'record exposes the copied quote id');
    $assert->is($record->text, 'hello world',
        'record removes IRC line-breaking control data');
    $assert->is($record->author, 'Tangy', 'record exposes copied author text');
    $assert->is($record->hits, 3, 'record exposes a bounded recall count');

    my $copy = $record->as_hash;
    $copy->{text} = 'mutated';
    $assert->is($record->text, 'hello world',
        'returned hashes cannot mutate the opaque record');
    $assert->ok(!$record->can('database') && !$record->can('dbh'),
        'record exposes neither database nor handle');

    my $ok = eval {
        Mediabot::Plugin::QuoteRecordV3->new(id => 0, text => 'bad');
        1;
    };
    $assert->like($@ // '', qr/id must be positive/,
        'invalid database identities fail closed');
};
