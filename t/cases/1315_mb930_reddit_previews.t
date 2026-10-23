use strict;
use warnings;
use utf8;
use JSON::PP ();
use IPC::Open3;
use Symbol qw(gensym);
return sub {
    my ($assert)=@_;my $err=gensym;
    my $pid=open3(undef,my $out,$err,$^X,'-I.','-It/lib','-MMB930RedditFixture','-e',
        'print JSON::PP->new->utf8->canonical->encode(MB930RedditFixture::run_contracts())');
    my $stdout=do {local $/;<$out>}//'';my $stderr=do {local $/;<$err>}//'';waitpid($pid,0);my $status=$?;
    my $rows=eval {JSON::PP::decode_json($stdout)};
    $assert->ok(!$status && !$stderr && ref($rows) eq 'ARRAY','mb930: isolated Reddit feature probe completes quietly');
    $assert->diag($stderr || $stdout) if $status || $stderr || ref($rows) ne 'ARRAY';
    return unless ref($rows) eq 'ARRAY';
    for my $r (@$rows) {$assert->ok($r->{ok},'mb930: '.$r->{case});$assert->diag(JSON::PP->new->canonical->ascii->encode($r)) unless $r->{ok}}
};
