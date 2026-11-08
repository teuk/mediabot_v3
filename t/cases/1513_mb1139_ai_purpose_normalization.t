use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use Mediabot::AI::Request qw(build_request validate_request request_summary);
my $id='s1p1-012345abcdef';
sub base { return (messages=>[{role=>'user',content=>'Select evidence'}]); }
for my $purpose (qw(meta_synthesis_passages meta_passage_repair)) {
    for my $raw ($purpose, " $purpose ", "\t$purpose\n") {
        for my $ids (undef, [], [$id,$id], ['invalid']) {
            my %args=(base(),purpose=>$raw);
            $args{passage_ids}=$ids if defined $ids;
            ok(defined(validate_request(\%args)), 'passage contract rejects missing or malformed catalogue');
            my $built=eval {build_request(%args)};
            ok(!defined($built) && $@ =~ /invalid AI request/, 'builder rejects invalid passage request');
            ok(!defined(request_summary(\%args)), 'invalid passage request has no summary');
        }
        my %args=(base(),purpose=>$raw,passage_ids=>[$id]);
        my $before=dclone(\%args);
        is(validate_request(\%args),undef,'valid passage request accepted with surrounding whitespace');
        my $request=eval {build_request(%args)};
        is($@,'','valid passage request builds');
        is($request->{purpose},$purpose,'built purpose is canonical');
        is((request_summary(\%args) // {})->{purpose},$purpose,'summary uses the same canonical purpose');
        is_deeply(\%args,$before,'caller data is unchanged');
        is_deeply($request->{passage_ids},[$id],'passage catalogue retained');
        is(validate_request($request),undef,'built request validates again');
    }
}
for my $raw ('wit',' wit ',"\tgeneric\n",'Custom.Purpose') {
    my $expected=$raw;$expected =~ s/^\s+|\s+$//g;
    my %args=(base(),purpose=>$raw);
    is(build_request(%args)->{purpose},$expected,'ordinary purpose normalized without changing case');
    is((request_summary(\%args) // {})->{purpose},$expected,'ordinary summary agrees');
    ok(defined validate_request({%args,passage_ids=>[$id]}),'ordinary purpose cannot carry a passage catalogue');
}
for my $bad (undef,''," \t ",'bad purpose',"wit\0",[], 'x' x 65) {
    ok(defined validate_request({base(),purpose=>$bad}),'invalid purpose remains rejected');
}
is(build_request(base())->{purpose},'generic','omitted purpose keeps generic default');
is(request_summary({base()})->{purpose},'generic','summary keeps generic default');
done_testing;
