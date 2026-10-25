package Mediabot::Plugin::LongestWord::Scores;

use strict;
use warnings;
use utf8;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use JSON::PP ();

sub week {
    my ($epoch, $zone) = @_;
    my $date = DateTime->from_epoch(epoch => $epoch, time_zone => $zone);
    return sprintf('%04d-W%02d', $date->week_year, $date->week_number);
}
sub oldest_week {
    my ($epoch, $zone) = @_;
    my $date = DateTime->from_epoch(epoch => $epoch, time_zone => $zone)->subtract(weeks => 51);
    return sprintf('%04d-W%02d', $date->week_year, $date->week_number);
}
sub valid_week {
    my ($value, $epoch, $zone) = @_;
    return 0 unless defined($value) && $value =~ /\A([0-9]{4})-W([0-9]{2})\z/;
    my ($year, $week) = ($1, $2);
    my $date = eval { DateTime->new(year => $year, month => 1, day => 4, time_zone => $zone)
        ->subtract(days => DateTime->new(year => $year, month => 1, day => 4)->day_of_week - 1)
        ->add(weeks => $week - 1) };
    return 0 unless $date && $week >= 1 && $week <= 53
        && sprintf('%04d-W%02d', $date->week_year, $date->week_number) eq $value;
    return $value ge oldest_week($epoch, $zone) && $value le week($epoch, $zone);
}
sub _hash { substr(sha256_hex(encode('UTF-8', $_[0])), 0, 40) }
sub player_key { 'p.' . _hash($_[0] . '|' . $_[1]) }
sub receipt_key { 'r.' . _hash($_[0]) }

sub decode_player {
    my ($raw) = @_;
    my $row = JSON::PP->new->decode($raw);
    die "word_score_document\n" unless ref($row) eq 'HASH' && ($row->{v} // 0) == 1
        && defined($row->{id}) && !ref($row->{id}) && $row->{id} =~ /\A(?:u\.[1-9][0-9]{0,18}|n\.[^\s\x00-\x1f\x7f]{1,64})\z/
        && defined($row->{scope}) && !ref($row->{scope}) && length($row->{scope}) <= 240
        && defined($row->{nick}) && !ref($row->{nick}) && length($row->{nick}) <= 32
        && $row->{nick} !~ /[\x00-\x1f\x7f]/
        && defined($row->{total}) && !ref($row->{total}) && "$row->{total}" =~ /\A[0-9]{1,12}\z/
        && defined($row->{rounds}) && !ref($row->{rounds}) && "$row->{rounds}" =~ /\A[0-9]{1,12}\z/
        && ref($row->{weeks}) eq 'HASH' && keys(%{$row->{weeks}}) <= 52;
    for my $week (keys %{$row->{weeks}}) {
        my $points = $row->{weeks}{$week};
        die "word_score_document\n" unless $week =~ /\A[0-9]{4}-W[0-9]{2}\z/
            && defined($points) && !ref($points) && "$points" =~ /\A[0-9]{1,12}\z/
            && $points <= $row->{total};
    }
    return $row;
}

# Atomically add a complete round and its receipt. If a successful write lost
# its acknowledgement, retry sees the receipt instead of adding twice.
sub changes {
    my ($snapshot, %args) = @_;
    my $key = receipt_key($args{scope});
    my $old_receipt = $snapshot->{values}{$key};
    if (defined $old_receipt) {
        my $receipt = JSON::PP->new->decode($old_receipt);
        die "word_score_receipt\n" unless ref($receipt) eq 'ARRAY' && @$receipt == 2
            && defined($receipt->[0]) && !ref($receipt->[0]) && $receipt->[0] =~ /\A[a-f0-9]{64}\z/
            && defined($receipt->[1]) && !ref($receipt->[1]) && "$receipt->[1]" =~ /\A[0-9]{1,2}\z/;
        return {} if $receipt->[0] eq $args{game} && $receipt->[1] >= $args{round};
    }
    my %changes;
    for my $player (@{$args{results}}) {
        my $key = player_key($args{scope}, $player->{id});
        my $row = exists($snapshot->{values}{$key}) ? decode_player($snapshot->{values}{$key})
            : { v => 1, id => $player->{id}, nick => $player->{nick}, scope => $args{scope}, total => 0, rounds => 0, weeks => {} };
        die "word_score_identity\n" unless $row->{id} eq $player->{id} && $row->{scope} eq $args{scope};
        $row->{nick} = $player->{nick};
        $row->{total} += $player->{points}; $row->{rounds}++;
        $row->{weeks}{$args{week}} += $player->{points};
        delete $row->{weeks}{$_} for grep { $_ lt $args{oldest} } keys %{$row->{weeks}};
        my $raw = JSON::PP->new->canonical->encode($row);
        decode_player($raw);
        $changes{$key} = $raw;
    }
    $changes{$key} = JSON::PP->new->encode([$args{game}, $args{round}]);
    return \%changes;
}

sub rows {
    my ($snapshot, $scope, $week) = @_;
    my @rows;
    for my $key (sort keys %{$snapshot->{values}}) {
        next unless $key =~ /\Ap\./;
        my $row = decode_player($snapshot->{values}{$key});
        die "word_score_key\n" unless $key eq player_key($row->{scope}, $row->{id});
        next unless $row->{scope} eq $scope;
        $row->{score} = defined($week) ? ($row->{weeks}{$week} // 0) : $row->{total};
        push @rows, $row if $row->{score} > 0;
    }
    @rows = sort { $b->{score} <=> $a->{score} || $a->{id} cmp $b->{id} } @rows;
    my ($rank, $last, $index) = (0, -1, 0);
    for my $row (@rows) { $index++; $rank = $index if $row->{score} != $last; $last = $row->{score}; $row->{rank} = $rank }
    return \@rows;
}

1;
