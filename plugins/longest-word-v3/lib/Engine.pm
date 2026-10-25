package Mediabot::Plugin::LongestWord::Engine;

use strict;
use warnings;
use utf8;
use Unicode::Normalize qw(NFD);

sub fold {
    my ($value) = @_;
    $value = lc $value;
    $value =~ tr/[]\\^/{}|~/;
    return $value;
}

sub normalize {
    my ($value) = @_;
    return unless defined($value) && !ref($value) && length($value) <= 32;
    $value =~ s/^\s+|\s+$//g;
    $value = uc $value;
    $value =~ s/Œ/OE/g; $value =~ s/Æ/AE/g;
    $value = NFD($value); $value =~ s/\pM//g;
    return $value =~ /\A[A-Z]{2,12}\z/ ? $value : undef;
}

sub new {
    my ($class, %args) = @_;
    return bless { phase => 'preparing', round => 0,
        rounds => $args{rounds}, duration => $args{duration},
        bonus => $args{bonus}, players => {}, completed => 0, round_best_length => 0 }, $class;
}

sub begin_round {
    my ($self, %args) = @_;
    die "dictionary_phase\n" unless $self->{phase} eq 'preparing';
    my %words = map { $_ => 1 } @{ $args{words} };
    die "dictionary_empty_rack\n" unless keys %words;
    $self->{words} = \%words;
    $self->{round_best_length} = 0;
    $self->{letters} = $args{letters};
    $self->{longest} = (sort { $b <=> $a } map { length($_) } keys %words)[0];
    $self->{opened_at} = $args{now};
    $self->{deadline} = $args{now} + $self->{duration};
    $self->{round}++;
    $self->{phase} = 'playing';
    delete $_->{word} for values %{ $self->{players} };
    return 1;
}

sub submit {
    my ($self, %args) = @_;
    return { error => 'closed' } unless $self->{phase} eq 'playing'
        && $args{now} < $self->{deadline};
    my $word = normalize($args{word});
    return { error => 'invalid' } unless defined($word) && $self->{words}{$word};
    return { error => 'not_longer', word => $word, minimum => $self->{round_best_length} + 1 }
        if length($word) <= $self->{round_best_length};
    my $player = $self->{players}{$args{id}};
    return { error => 'full' } if !$player && keys(%{ $self->{players} }) >= 32;
    $player ||= ($self->{players}{$args{id}} = {
        id => $args{id}, nick => $args{nick}, score => 0, tops => 0, best => '', rounds => 0,
    });
    $player->{nick} = $args{nick};
    $player->{word} = $word;
    $self->{round_best_length} = length($word);
    return { ok => 1, word => $word, points => length($word)
        + (length($word) == $self->{longest} ? $self->{bonus} : 0) };
}

sub ranking {
    my ($self) = @_;
    return [ map { { %$_ } } sort {
        $b->{score} <=> $a->{score} || $b->{tops} <=> $a->{tops} || $a->{id} cmp $b->{id}
    } values %{ $self->{players} } ];
}

sub close_round {
    my ($self, $now) = @_;
    return unless $self->{phase} eq 'playing';
    my $top_found = $self->{round_best_length} == $self->{longest};
    return unless $now >= $self->{opened_at} && ($now >= $self->{deadline} || $top_found);
    my @round;
    for my $player (values %{ $self->{players} }) {
        next unless defined $player->{word};
        my $length = length($player->{word});
        my $top = $length == $self->{longest} ? 1 : 0;
        my $points = $length + ($top ? $self->{bonus} : 0);
        $player->{score} += $points;
        $player->{tops} += $top;
        $player->{rounds}++;
        $player->{best} = $player->{word} if $length > length($player->{best});
        push @round, { id => $player->{id}, nick => $player->{nick}, word => $player->{word}, points => $points };
    }
    @round = sort { $b->{points} <=> $a->{points} || $a->{nick} cmp $b->{nick} } @round;
    my @solutions = sort grep { length($_) == $self->{longest} } keys %{ $self->{words} };
    delete $self->{words};
    $self->{completed}++;
    $self->{phase} = $self->{round} >= $self->{rounds} ? 'done' : 'between';
    return { results => \@round, solutions => \@solutions, longest => $self->{longest}, top_found => $top_found };
}

1;
