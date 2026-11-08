use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::PostEditor;
{
    package MB1153::Client;
    sub new { bless {answer => $_[1]}, $_[0] }
    sub submit {
        my ($self, $request, %args) = @_;
        $args{on_done}->({ok => 1, answer => $self->{answer}});
        return 1;
    }
}
sub edit {
    my ($draft, $answer) = @_;
    my $editor = Mediabot::Hailo::PostEditor->new(client => MB1153::Client->new($answer));
    my $result;
    $editor->submit(candidate => $draft, trigger => 'Tell me about the garden.',
        channel_language => 'en', on_done => sub { $result = $_[0] });
    return $result;
}
for my $pair (["isn't", 'is'], ["aren't", 'are'], ["wasn't", 'was'],
              ["weren't", 'were'], ["doesn't", 'does'], ["haven't", 'have'],
              ["hasn't", 'has'], ["hadn't", 'had'], ["wouldn't", 'would'],
              ["couldn't", 'could'], ["shouldn't", 'should'], ["mustn't", 'must'],
              ["needn't", 'need'], ["shan't", 'shall']) {
    for my $curly (0, 1) {
        my ($negative, $positive) = @$pair;
        $negative =~ s/'/’/g if $curly;
        my $draft = "The garden $negative stay quiet today";
        my $opposite = "The garden $positive stay quiet today";
        for my $direction ([$draft, $opposite], [$opposite, $draft]) {
            my $out = edit(@$direction);
            is($out->{reason}, 'anchor_rejected', 'adding/removing contracted negation is rejected');
            is($out->{line}, $direction->[0], 'original meaning is retained');
        }
        my $out = edit($draft, "$draft.");
        is($out->{reason}, 'edited', 'punctuation repair preserving contracted negation is accepted');
        is($out->{line}, "$draft.", 'accepted repair returned');
    }
}
done_testing;
