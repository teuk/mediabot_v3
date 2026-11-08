use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::PostEditor;
{
    package MB1154::Client;
    sub new { bless {answer => $_[1]}, $_[0] }
    sub submit {
        my ($self, $request, %args) = @_;
        $args{on_done}->({ok => 1, answer => $self->{answer}});
        return 1;
    }
}
sub edit {
    my ($draft, $answer) = @_;
    my $editor = Mediabot::Hailo::PostEditor->new(client => MB1154::Client->new($answer));
    my $result;
    $editor->submit(candidate => $draft, trigger => 'Quelle température ce soir ?',
        channel_language => 'fr', on_done => sub { $result = $_[0] });
    return $result;
}
for my $number ('5', '12', '1.5', '١٢') {
    for my $sign ('-', '−', '+') {
        my $signed = "La température sera $sign$number degrés ce soir";
        my $unsigned = "La température sera $number degrés ce soir";
        for my $pair ([$signed, $unsigned], [$unsigned, $signed]) {
            my $out = edit(@$pair);
            is($out->{reason}, 'anchor_rejected', 'addition/removal of explicit sign rejected');
            is($out->{line}, $pair->[0], 'draft preserved');
        }
        my $out = edit($signed, "$signed.");
        is($out->{reason}, 'edited', 'punctuation repair retains signed quantity');
    }
    my $draft = "La température sera -$number degrés ce soir";
    my $out = edit($draft, "La température sera +$number degrés ce soir");
    is($out->{reason}, 'anchor_rejected', 'negative-to-positive inversion rejected');
    is($out->{line}, $draft, 'signed draft retained');
}
for my $text ('Il reste 5 pommes', 'Les étapes sont 5 puis 12', 'La plage est 5-12 degrés') {
    is(edit($text, "$text.")->{reason}, 'edited', 'existing number formatting remains accepted');
}
done_testing;
