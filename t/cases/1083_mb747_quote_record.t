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
