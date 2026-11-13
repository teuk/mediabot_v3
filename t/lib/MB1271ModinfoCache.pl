use strict;
use warnings;
use Mediabot::UserCommands ();
use Mediabot::Helpers ();

{
    package MB1271::IRC;
    sub nick_folded { 'bot' }
    package MB1271::Channel;
    sub get_id { 77 }
    package MB1271::User;
    sub is_authenticated { $_[0]{auth} }
    sub has_level { $_[0]{admin} }
    sub handle { 'issuer' }
    sub nickname { 'issuer' }
    sub level_description { 'User' }
    package MB1271::Context;
    sub bot { $_[0]{bot} }
    sub nick { 'Issuer' }
    sub args { $_[0]{args} }
    sub user { $_[0]{user} }
    sub channel { '#TeSt' }
    sub message { undef }
    package MB1271::DB;
    sub prepare {
        my ($self,$sql)=@_;
        return undef if $sql =~ /^UPDATE/ && $self->{failure} eq 'prepare';
        return bless {db=>$self,sql=>$sql}, 'MB1271::Statement';
    }
    package MB1271::Statement;
    sub execute {
        my ($self,@bind)=@_;
        my $db=$self->{db};
        $self->{bind}=\@bind;
        if ($self->{sql} =~ /^UPDATE/) {
            push @{$db->{updates}}, \@bind;
            return 0 if $db->{failure} eq 'execute';
            $db->{level}=$bind[0] if $self->{sql} =~ /SET level=/;
        }
        return 1;
    }
    sub fetchrow_array {
        my ($self)=@_;
        return (42,$self->{db}{level}) if $self->{sql} =~ /SELECT u.id_user/;
        return (100); # Non-admin issuer deliberately lacks modification rights.
    }
    sub fetchrow_hashref {
        my ($self)=@_;
        $self->{db}{reads}++;
        return {level=>$self->{db}{level}};
    }
    sub finish { 1 }
}

return sub {
    my ($a)=@_;
    for my $case (
        ['demotion',450,0,'level',1,1,''],
        ['promotion',0,450,'level',1,1,''],
        ['prepare failure',450,0,'level',1,1,'prepare'],
        ['execute failure',450,0,'level',1,1,'execute'],
        ['unauthenticated',450,0,'level',0,1,''],
        ['denied',450,0,'level',1,0,''],
        ['automode',450,'NONE','automode',1,1,''],
        ['greet',450,'hello','greet',1,1,''],
    ) {
        my ($name,$initial,$value,$type,$auth,$admin,$failure)=@$case;
        my $db=bless {level=>$initial,failure=>$failure,reads=>0,updates=>[]},'MB1271::DB';
        my $other_channel={ts=>time,val=>450};
        my $other_user={ts=>time,val=>450};
        my $bot={dbh=>$db,irc=>bless({},'MB1271::IRC'),channels=>{'#test'=>bless({},'MB1271::Channel')},
            _uchan_level_cache=>{"42\0#other"=>$other_channel,"43\0#test"=>$other_user}};
        my $ctx=bless {bot=>$bot,args=>[$type,'target',$value],
            user=>bless({auth=>$auth,admin=>$admin},'MB1271::User')},'MB1271::Context';
        my $allowed=Mediabot::Helpers::checkUserChannelLevel($bot,undef,'#TEST',42,400);
        $a->is($allowed,$initial>=400?1:0,"$name: native helper primes authority cache");
        my $old=$bot->{_uchan_level_cache}{"42\0#test"};
        my $changed=$type eq 'level' && $auth && $admin && !$failure;
        my $notice_allowed;
        {
            no warnings qw(redefine once);
            local *Mediabot::UserCommands::botNotice=sub {
                my (undef,undef,$text)=@_;
                if ($text =~ /^Set level /) {
                    $notice_allowed=Mediabot::Helpers::checkUserChannelLevel($bot,undef,'#test',42,400);
                }
            };
            local *Mediabot::UserCommands::noticeConsoleChan=sub {};
            local *Mediabot::UserCommands::logBot=sub {};
            Mediabot::UserCommands::userModinfo_ctx($ctx);
        }
        my $expected=$changed?$value:$initial;
        $a->is(Mediabot::Helpers::checkUserChannelLevel($bot,undef,'#tEsT',42,400),
            $expected>=400?1:0,"$name: next native authorization uses confirmed level");
        if ($changed) {
            $a->is($notice_allowed,$value>=400?1:0,"$name: invalidation precedes success notice callback");
            $a->is($db->{reads},2,"$name: first post-change lookup rereads once");
            $a->is(join(',',@{$db->{updates}[0]}),"$value,42,77","$name: bound SQL target preserved");
        } else {
            $a->is($bot->{_uchan_level_cache}{"42\0#test"},$old,"$name: unchanged authorization retains cache object");
            $a->is($db->{reads},1,"$name: no needless cache refresh");
        }
        $a->is($bot->{_uchan_level_cache}{"42\0#other"},$other_channel,"$name: other channel retained");
        $a->is($bot->{_uchan_level_cache}{"43\0#test"},$other_user,"$name: other user retained");
    }
};
