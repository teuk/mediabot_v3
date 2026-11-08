use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::AI::MetaPolicy qw(settings);
{
    package MB1155::Conf;
    sub new { bless {value => $_[1], key => $_[2] // 'ENABLED'}, $_[0] }
    sub get { return $_[0]{value} if $_[1] eq 'meta_ai.'.$_[0]{key}; return undef }
}
for my $bad ('١', '１', '𝟙', "1\n", '1.0', '+1', ' 1') {
    my @warnings;
    my $got;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $got = settings(MB1155::Conf->new($bad));
    }
    is($got->{enabled}, 1, 'invalid enabled value uses enabled default');
    is($got->{legacy_enabled}, 0, 'invalid enabled value uses distinct legacy default');
    is_deeply(\@warnings, [], 'invalid config produces no numeric conversion warning');
}
for my $value ('0', '1', '00', '01') {
    my $got = settings(MB1155::Conf->new($value));
    is($got->{enabled}, 0+$value, 'valid ASCII setting accepted');
    is($got->{legacy_enabled}, 0+$value, 'valid ASCII legacy setting accepted');
}
for my $spec (['TIMEOUT','timeout',25,5,45], ['MAX_JOBS','max_jobs',2,1,4],
              ['DAILY_LIMIT','daily_limit',100,1,1000], ['MAX_TOKENS','tokens',2048,512,8192]) {
    my ($key,$field,$default,$lo,$hi) = @$spec;
    for my $case ([$lo,$lo], [$hi,$hi], [$lo-1,$default], [$hi+1,$default], ['１２',$default]) {
        my @warnings;
        my $got;
        { local $SIG{__WARN__} = sub {push @warnings, @_};
          $got = settings(MB1155::Conf->new($case->[0],$key)); }
        is($got->{$field}, $case->[1], "$key honors bounds and defaults");
        is_deeply(\@warnings, [], "$key validates before numeric conversion");
    }
}
done_testing;
