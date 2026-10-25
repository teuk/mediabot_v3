# MB958: exercise the native public read views in three clean load orders.
use strict;
use warnings;
use IPC::Open3 ();
use Symbol ();

return sub {
    my ($assert) = @_;
    for my $order (
        [qw(Stats::Radar Diagnostics::Commands UserCommands)],
        [qw(Diagnostics::Commands Stats::Radar UserCommands)],
        [qw(UserCommands Stats::Radar Diagnostics::Commands)],
    ) {
        my $code="require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly loaded facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('',map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code .= q{
            use utf8;
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            for my $pair ([mbRadar_ctx=>'Stats::Radar'],[mbFeatures_ctx=>'Diagnostics::Commands'],
                          [mbObservatory_ctx=>'Diagnostics::Commands']) {
                my ($name,$owner)=@$pair;
                my $native="Mediabot::$owner"->can($name);
                for my $api ('Mediabot::UserCommands','Mediabot') {
                    my $alias=$api->can($name);
                    die "missing legacy alias $name" unless $native && $alias
                        && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($alias);
                }
            }
            for my $name(qw(_mbFeatures_chanset_state _mbObservatory_uptime _mbObservatory_energy_label)) {
                die "missing helper alias $name" unless Scalar::Util::refaddr(Mediabot::UserCommands->can($name))
                    ==Scalar::Util::refaddr(Mediabot::Diagnostics::Commands->can($name));
            }
            my (@out,@sql,@bind,@chansets,@metrics);
            my $fail_prepare=0;
            no warnings 'redefine';
            local *Mediabot::UserCommands::botPrivmsg=sub {push @out,['message',$_[1],$_[2]];1};
            local *Mediabot::UserCommands::botNotice=sub {push @out,['notice',$_[1],$_[2]];1};
            local *Mediabot::UserCommands::_fmt_n=sub {'n('.$_[0].')'};
            local *Mediabot::Helpers::getIdChansetList=sub {$_[1] eq 'Games'?undef:$_[1]};
            local *Mediabot::Helpers::getIdChannelSet=sub {push @chansets,[@_[1..$#_]];$_[2] eq 'UrlTitle'};
            local *MB958Cold::DB::prepare=sub {
                my ($self,$query)=@_;push @sql,$query;
                return undef if $fail_prepare;
                die 'view introduced non-read SQL' unless $query=~/\A\s*SELECT\b/;
                die 'history event filter lost' unless $query=~/event_type IN \('public','action'\)/;
                my $rows=$query=~/DATE\(cl.ts\)/
                    ? [{d=>'2026-10-20',c=>4},{d=>'2026-10-21',c=>11}]
                    : [{msgs=>41,nicks=>3}];
                return bless {rows=>$rows},'MB958Cold::STH';
            };
            local *MB958Cold::STH::execute=sub {shift;push @bind,[@_];1};
            local *MB958Cold::STH::fetchrow_hashref=sub {shift @{$_[0]{rows}}};
            local *MB958Cold::STH::finish=sub {1};
            local *MB958Cold::Conf::get=sub {'off'};
            local *MB958Cold::Metrics::inc=sub {shift;push @metrics,[@_]};
            my $bot=bless {dbh=>bless({},'MB958Cold::DB'),conf=>bless({},'MB958Cold::Conf'),
                          metrics=>bless({},'MB958Cold::Metrics')},'Mediabot';
            my $call=sub {
                my ($name,$channel,@args)=@_;
                my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Émilie',channel=>$channel,args=>\@args);
                return Mediabot::UserCommands->can($name)->($ctx);
            };
            for my $name(qw(mbRadar_ctx mbFeatures_ctx mbObservatory_ctx)) {
                @out=();$call->($name,undef);
                die 'private command performed work' if @sql || @chansets || @metrics;
                die 'private syntax route changed' unless @out==1 && $out[0][0] eq 'notice'
                    && $out[0][1] eq 'Émilie' && $out[0][2]=~/Syntax:/;
            }
            @out=();$call->('mbFeatures_ctx','#one');
            die 'capabilities leaked or route changed' unless @out==8
                && !grep {$_->[0] ne 'notice' || $_->[1] ne 'Émilie'} @out;
            die 'capabilities introduced SQL' if @sql;
            die 'legacy Games default lost' unless grep {$_->[2]=~/games: on \(legacy default\)/} @out;
            die 'capabilities wrong channel' if grep {$_->[0] ne '#one'} @chansets;
            @out=();@chansets=();$call->('mbObservatory_ctx','#two');
            die 'observatory output changed' unless @out==2
                && !grep {$_->[0] ne 'message' || $_->[1] ne '#two'} @out;
            die 'formatter hook no longer late bound' unless $out[1][2]=~/n\(41\) msg\(s\) \/ n\(3\) nick\(s\)/;
            die 'energy or scope changed' unless $out[1][2]=~/energy lively/
                && $bind[-1][0] eq '#two' && !grep {$_->[0] ne '#two'} @chansets;
            die 'metric scope changed' unless $metrics[0][0] eq 'mediabot_observatory_total'
                && $metrics[0][1]{channel} eq '#two';
            $fail_prepare=1;@out=();$call->('mbObservatory_ctx','#empty');
            die 'unavailable activity fallback changed' unless @out==2 && $out[1][2]=~/energy silent/;
            $fail_prepare=0;@out=();$call->('mbRadar_ctx','#history','999d');
            die 'history window is not capped' unless $sql[-1]=~/INTERVAL 30 DAY/ && $bind[-1][0] eq '#history';
            die 'history route or formatter changed' unless @out==3
                && !grep {$_->[0] ne 'message' || $_->[1] ne '#history'} @out;
            die 'history total changed' unless $out[1][2]=~/total n\(15\) msgs/;
            $fail_prepare=1;@out=();$call->('mbRadar_ctx','#empty','0d');
            die 'minimum history window lost' unless $sql[-1]=~/INTERVAL 1 DAY/;
            die 'history empty fallback changed' unless @out==1 && $out[0][2]=~/no data in last 1d/;
            print 'checked';
        };
        my $err=Symbol::gensym();
        my $pid=IPC::Open3::open3(undef,my $out,$err,$^X,'-I.','-It/lib','-e',$code);
        my $stdout=do {local $/;<$out>} // '';
        my $stderr=do {local $/;<$err>} // '';
        waitpid($pid,0);
        $assert->is($?,0,"MB958 load order @$order: $stderr");
        $assert->is($stdout,'checked','real views preserve read scope, output routes and late formatter hooks');
    }
};
