package Mediabot::Plugin::WordSolverV3;

use strict;
use warnings;

our $MAX_WORDS = 4096;

sub letters {
    my ($class, $letters) = @_;
    die "dictionary_letters\n" unless defined($letters) && !ref($letters)
        && $letters =~ /\A[A-Za-z]{2,12}\z/;
    return join '', sort split //, uc $letters;
}

sub signatures {
    my ($class, $letters) = @_;
    $letters = $class->letters($letters);
    my %count; $count{$_}++ for split //, $letters;
    my @all = ('');
    for my $letter (sort keys %count) {
        @all = map { my $prefix = $_; map { $prefix . $letter x $_ } 0 .. $count{$letter} } @all;
    }
    return [ sort { length($b) <=> length($a) || $a cmp $b }
        grep { length($_) >= 2 } @all ];
}

sub result {
    my ($class, $letters, $words) = @_;
    $letters = $class->letters($letters);
    die "dictionary_payload\n" unless ref($words) eq 'ARRAY' && @$words <= $MAX_WORDS;
    my %allowed = map { $_ => 1 } @{ $class->signatures($letters) };
    my %seen;
    for my $word (@$words) {
        die "dictionary_dictionary_corrupt\n" unless defined($word) && !ref($word)
            && $word =~ /\A[A-Z]{2,12}\z/
            && $allowed{join '', sort split //, $word};
        $seen{$word} = 1;
    }
    my @ordered = sort { length($b) <=> length($a) || $a cmp $b } keys %seen;
    return { ok => 1, letters => $letters, words => \@ordered,
        longest => @ordered ? length($ordered[0]) : 0 };
}

sub solve {
    my ($class, $dbh, $letters) = @_;
    $letters = $class->letters($letters);
    my @signatures = @{ $class->signatures($letters) };
    my (@words, $rows);
    $rows = 0;
    my $result;
    my $ok = eval {
        $dbh->begin_work;
        while (@signatures) {
            my @batch = splice @signatures, 0, 128;
            my $limit = $MAX_WORDS + 1 - $rows;
            my $sql = 'SELECT `word`,`sorted` FROM `DICT` FORCE INDEX (`sorted`) WHERE `sorted` IN ('
                . join(',', ('?') x @batch) . ") LIMIT $limit";
            my $sth = $dbh->prepare($sql);
            $sth->execute(@batch);
            while (my $row = $sth->fetchrow_arrayref) {
                die "dictionary_dictionary_limit\n" if ++$rows > $MAX_WORDS;
                my ($word, $signature) = @$row;
                die "dictionary_dictionary_corrupt\n" unless defined($word) && defined($signature)
                    && $word =~ /\A[A-Z]{2,12}\z/
                    && join('', sort split //, $word) eq $signature;
                push @words, $word;
            }
            $sth->finish;
        }
        $result = $class->result($letters, \@words);
        1;
    };
    my $error = $@;
    my $rolled_back = eval { $dbh->rollback; 1 };
    die "dictionary_query\n" unless $ok && $rolled_back;
    return $result;
}

1;
