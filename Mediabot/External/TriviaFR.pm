package Mediabot::External::TriviaFR;

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Encode qw(encode);
use Unicode::Normalize qw(NFD);

my $CATALOG = File::Spec->catfile(dirname(abs_path(__FILE__)), '..', 'Games', 'data', 'trivia-fr.json');
my $BANK;
my %CATEGORIES = (
    9=>'Culture générale',10=>'Littérature',11=>'Cinéma',12=>'Musique',
    14=>'Télévision',15=>'Jeux vidéo',17=>'Sciences et nature',18=>'Informatique',
    20=>'Mythologie et traditions',21=>'Sports',22=>'Géographie',23=>'Histoire',25=>'Arts',27=>'Animaux',
);

sub categories { return {%CATEGORIES} }
sub answer_key {
    my ($text) = @_;
    return '' unless defined($text) && !ref($text);
    $text = lc $text;
    $text =~ s/œ/oe/g; $text =~ s/æ/ae/g;
    $text = NFD($text); $text =~ s/\pM//g;
    $text =~ tr/’/'/;
    $text =~ s/\s+/ /g; $text =~ s/^\s+|\s+$//g;
    return $text;
}
sub _text {
    my ($value, $max) = @_;
    return defined($value) && !ref($value) && length($value)
        && $value !~ /[\x00-\x1f\x7f-\x9f]/ && length(encode('UTF-8',$value)) <= $max;
}

sub parse_catalog {
    my ($raw) = @_;
    die "trivia_fr_catalog_size\n" unless defined($raw) && !ref($raw) && length($raw) <= 8*1024*1024;
    my $doc = JSON::PP->new->utf8->decode($raw);
    die "trivia_fr_catalog_header\n" unless ref($doc) eq 'HASH'
        && defined($doc->{version}) && !ref($doc->{version}) && $doc->{version} eq '1'
        && _text($doc->{language},2) && $doc->{language} eq 'fr'
        && _text($doc->{license},32) && $doc->{license} eq 'CC-BY-SA-4.0'
        && ref($doc->{questions}) eq 'ARRAY' && @{$doc->{questions}} && @{$doc->{questions}} <= 20000;
    my %seen;
    for my $q (@{$doc->{questions}}) {
        die "trivia_fr_catalog_question\n" unless ref($q) eq 'HASH'
            && defined($q->{id}) && !ref($q->{id}) && $q->{id} =~ /\Aoqdb-[1-9][0-9]{0,5}-[1-9][0-9]{0,2}\z/
            && !$seen{$q->{id}}++ && defined($q->{category_id}) && !ref($q->{category_id})
            && exists($CATEGORIES{$q->{category_id}}) && _text($q->{category},64)
            && $q->{category} eq $CATEGORIES{$q->{category_id}}
            && defined($q->{difficulty}) && !ref($q->{difficulty}) && $q->{difficulty} =~ /\A(?:easy|medium|hard)\z/
            && _text($q->{question},300) && _text($q->{correct_answer},90)
            && ref($q->{incorrect_answers}) eq 'ARRAY' && @{$q->{incorrect_answers}} == 3
            && _text($q->{theme},256) && _text($q->{author},128);
        my @choices = ($q->{correct_answer}, @{$q->{incorrect_answers}});
        my (%choices, $bytes);
        $bytes = 0;
        for my $choice (@choices) {
            die "trivia_fr_catalog_choices\n" unless _text($choice,90) && length(answer_key($choice))
                && !$choices{answer_key($choice)}++;
            $bytes += length(encode('UTF-8',$choice)) + 4;
        }
        die "trivia_fr_catalog_choices\n" if $bytes > 260;
    }
    return $doc;
}

# Invoked inside the existing Trivia worker. No remote request, SQL or state write.
sub fetch {
    my ($category, $difficulty, %opts) = @_;
    my $doc = $BANK // eval {
        open my $fh, '<:raw', $CATALOG or die "trivia_fr_catalog_open\n";
        my $raw = ''; my $read = read($fh, $raw, 8*1024*1024+1);
        close $fh;
        die "trivia_fr_catalog_read\n" unless defined($read);
        parse_catalog($raw);
    };
    return {ok=>0,error=>'fr_catalog',stage=>'fr_catalog'} unless $doc;
    $BANK = $doc;
    return {ok=>0,error=>'fr_category',stage=>'fr_select'}
        if defined($category) && (ref($category) || !exists($CATEGORIES{$category}));
    return {ok=>0,error=>'fr_difficulty',stage=>'fr_select'} if defined($difficulty)
        && (ref($difficulty) || $difficulty !~ /\A(?:easy|medium|hard)\z/);
    my @pool = grep {(!defined($category) || $_->{category_id} == $category)
        && (!defined($difficulty) || $_->{difficulty} eq $difficulty)} @{$doc->{questions}};
    return {ok=>0,error=>'fr_empty',stage=>'fr_select'} unless @pool;
    my %excluded = map {$_=>1} grep {defined($_) && !ref($_)}
        @{ref($opts{exclude_ids}) eq 'ARRAY' ? $opts{exclude_ids} : []};
    my @fresh = grep {!$excluded{$_->{id}}} @pool;
    @pool = @fresh if @fresh;
    my $q = $pool[int(rand(scalar @pool))];
    return {ok=>1,question=>{%$q, incorrect_answers=>[@{$q->{incorrect_answers}}]},
        language=>'fr',source=>'OpenQuizzDB',stage=>'fr_select'};
}

1;
