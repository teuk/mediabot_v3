# t/cases/53_user_id_level_exact_match.t
# =============================================================================
# Static regression checks for getIdUserLevel().
#
# USER_LEVEL.description is a level name, not a SQL LIKE pattern.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_user_id_level_exact {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_user_id_level_exact {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    # MB955: verify the live API in independent interpreters, including
    # domain-first imports, old bot methods and denied command boundaries.
    require IPC::Open3;
    require Symbol;
    for my $order (
        [qw(Users::Levels Users::Profiles UserCommands)],
        [qw(Users::Profiles Users::Levels UserCommands)],
        [qw(UserCommands Users::Levels Users::Profiles)],
    ) {
        my $code="require Mediabot::$order->[0];\n";
        $code.=q{die 'domain eagerly loaded facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code.=join('',map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code.=q{
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            my %owners=(
                Levels=>[qw(getIdUserLevel getLevelUser getUserLevelDesc getUserChannelLevel)],
                Profiles=>[qw(userStats_ctx userInfo_ctx userGreet_ctx)],
            );
            for my $owner(keys %owners){for my $name(@{$owners{$owner}}){
                my $native="Mediabot::Users::$owner"->can($name);
                my $legacy=Mediabot::UserCommands->can($name);
                my $method=Mediabot->can($name);
                die "missing alias/method: $name" unless $native && $legacy && $method
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($legacy)
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($method);
            }}
            die 'empty level inputs' if defined Mediabot::UserCommands::getIdUserLevel({},'')
                || defined Mediabot::UserCommands::getLevelUser({},'')
                || defined Mediabot::UserCommands::getUserLevelDesc({},'');
            die 'empty channel identity' unless defined Mediabot::UserCommands::getUserChannelLevel({},undef,'',42)
                && Mediabot::UserCommands::getUserChannelLevel({},undef,'',42)==0;
            my (@notices,@public);
            {
                no warnings 'redefine';
                local *Mediabot::UserCommands::botNotice=sub {shift;push @notices,[@_]};
                local *Mediabot::UserCommands::botPrivmsg=sub {shift;push @public,[@_]};
                my $bot=bless {},'MB955Load::Bot';
                my $call=sub {
                    my($name,$args,$auth,$allow,$expected)=@_;
                    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'alice',channel=>undef,args=>$args);
                    $ctx->{_user_fetched}=1;
                    $ctx->{user}=bless {auth=>$auth,allow=>$allow,expected=>$expected},'MB955Load::User';
                    Mediabot::UserCommands->can($name)->($ctx);
                };
                $call->('userInfo_ctx',['bob'],0,1,'Administrator');
                die 'userinfo auth guard' unless $bot->{notices}[-1][1] eq 'You must be logged in to use this command.';
                $call->('userInfo_ctx',['bob'],1,0,'Administrator');
                die 'userinfo level guard' unless $bot->{notices}[-1][1] eq 'Your level does not allow you to use this command.';
                $call->('userStats_ctx',[],1,0,'Master');
                die 'userstats level guard' unless $bot->{notices}[-1][1] eq 'Your level does not allow you to use this command.';
                $call->('userInfo_ctx',[],1,1,'Administrator');
                die 'userinfo late notice hook' unless $notices[-1][1] eq 'Syntax: userinfo <username>';
                $call->('userGreet_ctx',[],0,0,'unused');
                die 'private greet syntax' unless $notices[-1][1] eq 'Syntax (in private): greet #channel <nick>';
                die 'private views leaked public output' if @public;
            }
            print 'checked';
            package MB955Load::User;
            sub is_authenticated {$_[0]{auth}}
            sub has_level {die 'wrong requested level' unless $_[1] eq $_[0]{expected};$_[0]{allow}}
            package MB955Load::Bot;
            sub botNotice {my($s,@a)=@_;push @{$s->{notices}},\@a}
        };
        my $err=Symbol::gensym();
        my $pid=IPC::Open3::open3(undef,my $out,$err,$^X,'-I.','-It/lib','-e',$code);
        my $stdout=do{local $/;<$out>} // '';
        my $stderr=do{local $/;<$err>} // '';
        waitpid($pid,0);
        $assert->ok($?==0 && $stdout eq 'checked' && $stderr eq '',
            'mb955: aliases, load order, empty-input and role guards: '.join('/',@$order)
                .($stderr ne '' ? " ($stderr)" : ''));
    }

    my $src  = _slurp_user_id_level_exact(File::Spec->catfile('.', 'Mediabot', 'Users', 'Levels.pm'));
    my $func = _extract_sub_user_id_level_exact($src, 'getIdUserLevel');

    $assert->ok(
        $func =~ /SELECT id_user_level FROM USER_LEVEL WHERE description = \?/,
        'getIdUserLevel uses exact USER_LEVEL.description match'
    );

    $assert->ok(
        $func !~ /SELECT id_user_level FROM USER_LEVEL WHERE description like \?/i,
        'getIdUserLevel no longer uses LIKE'
    );

    $assert->ok(
        $func =~ /return undef unless defined\(\$sLevel\) && \$sLevel ne ''/,
        'getIdUserLevel rejects empty level input'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'getIdUserLevel handles prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$sLevel\)\)/,
        'getIdUserLevel handles execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return undef;/s,
        'getIdUserLevel finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \$id_user_level;/,
        'getIdUserLevel stores result before returning'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \$id_user_level;/s,
        'getIdUserLevel finishes statement before final return'
    );
};
