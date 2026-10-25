# MB957: exercise real module boundaries in clean interpreters, before aliases
# or test-local transport overrides can have been inherited from another case.
use strict;
use warnings;
use IPC::Open3 ();
use Symbol ();

return sub {
    my ($assert) = @_;
    for my $order (
        [qw(Users::Horoscope Users::AchievementView UserCommands)],
        [qw(Users::AchievementView Users::Horoscope UserCommands)],
        [qw(UserCommands Users::Horoscope Users::AchievementView)],
    ) {
        my $code = "require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly loaded facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('', map { "require Mediabot::$_;\n" } @$order[1..$#$order]);
        $code .= q{
            use utf8;
            require Scalar::Util;
            require Encode;
            require File::Temp;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            require Mediabot::Achievements;
            for my $pair ([mbHoroscope_ctx=>'Horoscope'], [mbAchievements_ctx=>'AchievementView']) {
                my ($name,$owner)=@$pair;
                my $native="Mediabot::Users::$owner"->can($name);
                for my $api ('Mediabot::UserCommands','Mediabot') {
                    my $alias=$api->can($name);
                    die "missing legacy API $api/$name" unless $native && $alias
                        && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($alias);
                }
            }
            # The old package hash and helper names remain the same shared API.
            local $Mediabot::UserCommands::HOROSCOPE_SLUG_OF{'Bélier'}='fixture';
            die 'zodiac table alias diverged' unless
                Mediabot::Users::Horoscope::_horoscope_slug_from_sign('Bélier') eq 'fixture';
            $Mediabot::UserCommands::HOROSCOPE_SLUG_OF{'Bélier'}='aries';
            my (@out,@progress,@checks,@api);
            my $allowed=0;
            my $queries=0;
            no warnings 'redefine';
            local *Mediabot::UserCommands::botPrivmsg=sub {push @out,['message',$_[1],$_[2]];1};
            local *Mediabot::UserCommands::botNotice=sub {push @out,['notice',$_[1],$_[2]];1};
            local *Mediabot::UserCommands::_ach_progress=sub {shift;push @progress,[@_];27};
            local *Mediabot::UserCommands::_birthday_valid_date=sub {push @checks,[@_];1};
            local *Mediabot::Helpers::chanset_enabled=sub {$allowed};
            local *Mediabot::Helpers::channel_lang=sub {'fr'};
            local *Mediabot::External::Horoscope::daily_line=sub {push @api,[@_];undef};
            local *MB957Cold::DB::prepare=sub {++$queries;die 'no live SQL in this fixture'};
            local *MB957Cold::Logger::log=sub {};
            local *MB957Cold::Checks::check_horoscope=sub {shift;push @checks,[@_]};
            my $bot=bless {dbh=>bless({},'MB957Cold::DB'),
                logger=>bless({},'MB957Cold::Logger')},'Mediabot';
            my $call=sub {
                my ($name,$channel,@args)=@_;
                my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Émilie',channel=>$channel,args=>\@args);
                return Mediabot::UserCommands->can($name)->($ctx);
            };
            $call->('mbHoroscope_ctx','#quiet','lion');
            die 'Games refusal reached source work' if $queries || @api || @progress;
            die 'Games refusal missing' unless @out==1 && $out[0][0] eq 'notice'
                && $out[0][2]=~/Games are disabled/;
            $allowed=1;@out=();
            $bot->{achievements}=bless({},'MB957Cold::Checks');
            srand(957); my $next=rand(); srand(957);
            $call->('mbHoroscope_ctx','#room','lion');
            die 'global random sequence changed' unless rand()==$next;
            die 'horoscope routing/size changed' unless @out==2
                && !grep {$_->[0] ne 'message' || $_->[1] ne '#room'
                    || length(Encode::encode('UTF-8',$_->[2]))>400} @out;
            die 'persistent progress seam missing' unless @progress==1
                && $progress[0][0] eq 'horoscope' && $progress[0][2] eq '#room'
                && $checks[-1][2]==27 && $bot->{_horoscope_count}{'Émilie'}==1;
            die 'calendar seam missing' unless
                scalar(@{[Mediabot::UserCommands::_horoscope_zodiac_sign(21,3)]})==3
                && $checks[-1][0]==2000;
            @out=();$allowed=0;
            $call->('mbHoroscope_ctx',undef,'lion');
            die 'private horoscope should remain usable' unless @out==2
                && !grep {$_->[1] ne 'Émilie'} @out;
            my $dir=File::Temp::tempdir(CLEANUP=>1);
            my $a=Mediabot::Achievements->new(path=>"$dir/achievements.json");
            $a->set_progress('distinct_words','Émilie','#room',980);
            $a->unlock('Émilie','#room','first_msg');
            $bot->{achievements}=$a;@out=();
            $call->('mbAchievements_ctx','#room','progress');
            die 'achievement details leaked to channel' unless @out>1
                && !grep {$_->[0] ne 'notice' || $_->[1] ne 'Émilie'} @out;
            die 'missing real progress values' unless grep {$_->[2]=~/980\/1k \(98%\)/} @out;
            @out=();
            $call->('mbAchievements_ctx','#room','list');
            die 'achievement catalogue route changed' unless @out>1
                && !grep {$_->[0] ne 'message' || $_->[1] ne 'Émilie'} @out;
            die 'locked secrets leaked in list' if grep {$_->[2]=~/Night King|Insomniac/} @out;
            print 'checked';
        };
        my $err=Symbol::gensym();
        my $pid=IPC::Open3::open3(undef,my $out,$err,$^X,'-I.','-It/lib','-e',$code);
        my $stdout=do {local $/;<$out>} // '';
        my $stderr=do {local $/;<$err>} // '';
        waitpid($pid,0);
        $assert->is($?,0,"MB957 load order @$order: $stderr");
        $assert->is($stdout,'checked','native commands, legacy aliases and late hooks exercised');
    }
};
