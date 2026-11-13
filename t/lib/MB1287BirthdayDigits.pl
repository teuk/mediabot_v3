use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Users::Birthdays ();
use Time::Local qw(timelocal);
return sub {
    my (@warnings,@notices,@writes);my $lookups=0;
    local $SIG{__WARN__}=sub {push @warnings,@_};
    no warnings qw(redefine once);
    local *Mediabot::Users::Birthdays::getIdUser=sub {$lookups++;7};
    local *Mediabot::Users::Birthdays::botNotice=sub {push @notices,$_[2];1};
    local *Mediabot::Users::Birthdays::logBot=sub {1};
    my $db=bless {writes=>\@writes},'MB1287DB';
    my $ctx=bless {bot=>{dbh=>$db}},'MB1287Context';
    for my $date ("12/1\x{660}/2024", "1\x{662}/10/2024", "12/10/20\x{662}4",
                  "\x{661}\x{662}/10/2024", "12/1\x{ff10}/2024", "12/1\x{660}") {
        @writes=();@notices=();$lookups=0;
        my $ok=eval {Mediabot::Users::Birthdays::_birthday_add_ctx($ctx,'Alice',$date);1};
        ok($ok,'non-ASCII date is rejected without throwing');
        is_deeply([\@writes,$lookups,\@notices],[[],0,['Date format must be dd/mm or dd/mm/YYYY.']],
            'non-ASCII input cannot resolve a user or update a birthday');
    }
    for my $row (['12/10/2024','2024-10-12'],['1/2','02-01'],['29/02','02-29'],
                  ['29/02/2000','2000-02-29'],[undef,undef],['',undef]) {
        @writes=();@notices=();$lookups=0;
        is(Mediabot::Users::Birthdays::_birthday_add_ctx($ctx,'Alice',$row->[0]),1,
            'ordinary dates and explicit clearing still succeed');
        is_deeply(\@writes,[[$row->[1],7]],'valid date keeps its original normalization and single write');
    }
    @writes=();@notices=();$lookups=0;
    Mediabot::Users::Birthdays::_birthday_add_ctx($ctx,'Alice','29/02/1900');
    is_deeply([\@writes,$lookups,\@notices],[[],0,['Invalid birthday date.']],
        'Gregorian century non-leap year remains rejected before SQL');
    for my $args ([2024,"1\x{660}",12],[2024,10,"1\x{662}"],["20\x{662}4",10,12]) {
        is(Mediabot::Users::Birthdays::_birthday_valid_date(@$args),0,
            'calendar helper rejects Unicode digits before numeric conversion');
    }
    for my $value ("1\x{660}-12", "2024-10-1\x{662}", "20\x{662}4-10-12") {
        my ($month,$day)=Mediabot::Users::Birthdays::_birthday_mmdd_from_value($value);
        ok(!defined($month) && !defined($day),'non-ASCII stored dates are excluded from the upcoming list');
    }
    my $now=timelocal(0,0,12,1,0,2026);
    for my $args (["1\x{660}",12],[10,"1\x{662}"],[undef,12],[2,30]) {
        is(Mediabot::Users::Birthdays::_birthday_days_ahead(@$args,$now),undef,
            'invalid calendar components cannot produce a misleading countdown');
    }
    is(Mediabot::Users::Birthdays::_birthday_days_ahead(1,2,$now),1,'ordinary next-day birthday remains one day away');
    is(Mediabot::Users::Birthdays::_birthday_days_ahead(2,29,timelocal(0,0,12,27,1,2026)),1,
        'February 29 remains observed on February 28 in non-leap years');
    is_deeply(\@warnings,[],'date validation and formatting emit no numeric conversion warnings');
};
package MB1287DB;
sub prepare {bless {db=>$_[0]},'MB1287Statement'}
package MB1287Statement;
sub execute {my ($s,@args)=@_;push @{$s->{db}{writes}},\@args;1}
sub finish {1}
package MB1287Context;
sub bot {$_[0]{bot}}
sub nick {'Caller'}
sub message {undef}
