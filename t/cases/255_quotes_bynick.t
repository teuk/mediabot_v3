# t/cases/255_quotes_bynick.t
# Verify mbQuoteByNick structure and DB balance.
use strict; use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _slurp { open my $fh,'<:raw',$_[0] or die $!; local $/; <$fh> }
sub _sub { my($s,$n)=@_; my $re=qr/^[ \t]*sub[ \t]+\Q$n\E\b[^{]*\{/m;
    return undef unless $s=~/$re/g; my($st,$p,$d)=($-[0],pos($s),1);
    while($p<length($s)){my $c=substr($s,$p,1);$d++ if $c eq '{';$d-- if $c eq '}';
    return substr($s,$st,$p+1-$st) if $d==0; $p++} undef }
return sub {
    my ($assert) = @_;
    my $src  = _slurp(File::Spec->catfile('.','Mediabot','Quotes.pm'));
    my $body = _sub($src, 'mbQuoteByNick');
    $assert->ok(defined $body, 'mbQuoteByNick sub found');
    $assert->like($body // '', qr/QUOTES/, 'mbQuoteByNick queries QUOTES table');
    $assert->like($body // '', qr/->finish/, 'mbQuoteByNick calls ->finish');
    # prepare/finish balance — 3 prepares, 3 finishes (or 3p/4f if double-branch)
    my @preps = ($body =~ /->prepare\(/g);
    my @fins  = ($body =~ /->finish/g);
    $assert->ok(scalar(@fins) >= scalar(@preps),
        'mbQuoteByNick: at least one finish per prepare');
    $assert->like($body // '', qr/nick/i,
        'mbQuoteByNick filters by nick');
    $assert->like($body // '', qr/B26ext|B26|fix/i,
        'mbQuoteByNick has B26 fix comment on error paths');

    # MB924: real handlers, public compatibility alias and Context on SQLite.
    # Controlled random fractions prove every exclusion rank without luck.
    require JSON::PP;
    my $probe = <<'MB924_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN {
    *CORE::GLOBAL::rand = sub {
        my ($max) = @_; $max = 1 unless defined $max;
        return 0.25 * $max unless $MB924::Random::active;
        push @{$MB924::Random::bounds}, 0+$max;
        my $fraction = @{$MB924::Random::fractions} ? shift @{$MB924::Random::fractions} : 0;
        return $fraction * $max;
    };
}
use DBI;
use JSON::PP;
use Mediabot::Quotes;
use Mediabot::Mediabot;
use Mediabot::Context;
{
    package MB924::DBI; our @ISA = ('DBI');
    package MB924::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($s,$sql,@rest) = @_;
        my $trace = $s->{private_mb924};
        my $selected = $sql =~ /SELECT q\.id_quotes.*LIMIT 1 OFFSET \?/s;
        my $retry = $trace && $selected && ++$trace->{selects} == 2;
        push @{$trace->{sql}},$sql if $trace;
        $s->do('DELETE FROM QUOTES WHERE id_quotes=21') if $retry && ($trace->{fail}//'') eq 'empty';
        my $actual = $sql;
        $actual =~ s/FROM QUOTES q/FROM MB924_MISSING q/ if $retry && ($trace->{fail}//'') eq 'prepare';
        my $sth = $s->SUPER::prepare($actual,@rest);
        $sth->{private_mb924} = {trace=>$trace,sql=>$sql,retry=>$retry} if $sth && $trace;
        return $sth;
    }
    package MB924::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($s,@bind) = @_;
        my $p = $s->{private_mb924};
        push @{$p->{trace}{binds}},[$p->{sql},@bind] if $p;
        $bind[-1] = 'invalid-offset' if $p && $p->{retry} && ($p->{trace}{fail}//'') eq 'execute';
        return $s->SUPER::execute(@bind);
    }
    sub finish {
        my ($s) = @_;
        my $p = $s->{private_mb924};
        push @{$p->{trace}{finished}},$p->{sql} if $p;
        return $s->SUPER::finish;
    }
    package MB924::Log; sub log {1}
}
$INC{'MB924/DBI.pm'} = __FILE__;
my @ids = (10,21,35,77,99);
sub run {
    my (%a) = @_;
    my $h = DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB924::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $h->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $h->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $h->do('CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,id_channel INTEGER,id_user INTEGER,quotetext TEXT,hits INTEGER)');
    $h->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $h->do('INSERT INTO USER VALUES(1,?)',undef,$a{author}//'Alice');
    $h->do(q{INSERT INTO USER VALUES(2,'Bob')});
    for my $i (0..$a{count}-1) {
        $h->do('INSERT INTO QUOTES VALUES(?,1,1,?,0)',undef,$ids[$i],"été citation $ids[$i]");
    }
    $h->do(q{INSERT INTO QUOTES VALUES(200,2,1,'other channel',0)});
    $h->do(q{INSERT INTO QUOTES VALUES(201,1,2,'other author',0)});
    my $trace = {sql=>[],binds=>[],finished=>[],selects=>0,fail=>$a{fail}};
    $h->{private_mb924} = $trace;
    my $b = {dbh=>$h,logger=>bless({},'MB924::Log'),sent=>[]};
    my $target = $a{target}//'Alice';
    my $key = '#test:'.$target;
    $b->{_quote_bynick_last}{$key} = $a{last} if defined $a{last};
    local $MB924::Random::active = 1;
    local $MB924::Random::bounds = [];
    local $MB924::Random::fractions = [@{$a{fractions}//[0]}];
    my @warnings; local $SIG{__WARN__} = sub {push @warnings,@_};
    my $ctx = Mediabot::Context->new(bot=>$b,nick=>'Reader',channel=>'#test',command=>'quote',args=>[$target]);
    my $method = $a{entry} eq 'module' ? \&Mediabot::Quotes::mbQuoteByNick : \&Mediabot::mbQuoteByNick;
    my $ret = $method->($ctx);
    my $out = {return=>$ret,sent=>$b->{sent},cache=>$b->{_quote_bynick_last}//{},
        sql=>[@{$trace->{sql}}],binds=>[@{$trace->{binds}}],finished=>[@{$trace->{finished}}],
        bounds=>$MB924::Random::bounds,warnings=>\@warnings,
        rows=>$h->selectall_arrayref('SELECT * FROM QUOTES ORDER BY id_quotes')};
    $h->disconnect;
    return $out;
}
no warnings qw(redefine once);
local *Mediabot::Quotes::botPrivmsg = sub {push @{$_[0]{sent}},['PRIVMSG',$_[1],$_[2]];1};
local *Mediabot::Quotes::botNotice = sub {push @{$_[0]{sent}},['NOTICE',$_[1],$_[2]];1};
local *Mediabot::Helpers::botNotice = sub {push @{$_[0]{sent}},['NOTICE',$_[1],$_[2]];1};
my %out;
for my $entry (qw(module facade)) {
    # Exhaust every possible alternative rank, including exclusion at either end.
    for my $n (2,3,5) {
        for my $initial (0..$n-1) {
            for my $rank (0..$n-2) {
                $out{matrix}{$entry}{$n}{$initial}{$rank} = run(entry=>$entry,count=>$n,last=>$ids[$initial],
                    fractions=>[($initial+0.1)/$n,($rank+0.1)/($n-1)]);
            }
        }
    }
    $out{repeated_draws}{$entry} = run(entry=>$entry,count=>2,last=>10,fractions=>[0,0,0,0,0]);
    $out{high_draws}{$entry} = run(entry=>$entry,count=>5,last=>10,fractions=>[0,0.999999]);
    for my $spec (
        ['first',5,undef,'Alice','Alice',[0.5]],
        ['nonrepeat',5,10,'Alice','Alice',[0.5]],
        ['only_quote',1,10,'Alice','Alice',[0.9]],
        ['removed_last',3,999,'Alice','Alice',[0.5]],
        ['prefix',3,undef,'Alice','Ali',[0.9]],
        ['contains',3,undef,'xAlicex','Alice',[0.5]],
        ['underscore',3,undef,'Bob_','Bob_',[0.5]],
        ['percent',3,undef,'100%','100%',[0.5]],
        ['bang',3,undef,'a!b','a!b',[0.5]],
        ['missing',3,undef,'Alice','Missing',[0.5]]) {
        my ($label,$n,$last,$author,$target,$fractions) = @$spec;
        $out{nominal}{$entry}{$label} = run(entry=>$entry,count=>$n,last=>$last,author=>$author,target=>$target,fractions=>$fractions);
    }
    for my $failure (qw(prepare execute empty)) {
        $out{failure}{$entry}{$failure} = run(entry=>$entry,count=>2,last=>10,fail=>$failure,fractions=>[0,0.9]);
    }
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB924_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start native quote-by-nick probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native quote-by-nick probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    my @ids = (10,21,35,77,99);
    my $quote_text = sub {"\x{e9}t\x{e9} citation $_[0]"};
    my $rows = sub {
        my ($n) = @_;
        return [(map {[$ids[$_],1,1,$quote_text->($ids[$_]),0]} 0..$n-1),
            [200,2,1,'other channel',0],[201,1,2,'other author',0]];
    };
    my (@got,@want);
    for my $entry (qw(module facade)) {
        my $v = $r->{repeated_draws}{$entry};
        push @got, [@$v{qw(return sent cache bounds warnings)},$v->{rows}];
        push @want, [1,[['PRIVMSG','#test','[21] <Alice> '.$quote_text->(21)]],
            {'#test:Alice'=>21},[2,1],[],$rows->(2)];
        $v = $r->{high_draws}{$entry};
        push @got, [@$v{qw(return sent cache bounds warnings)},$v->{rows}];
        push @want, [1,[['PRIVMSG','#test','[99] <Alice> '.$quote_text->(99)]],
            {'#test:Alice'=>99},[5,4],[],$rows->(5)];
    }
    $assert->is($json->encode(\@got),$json->encode(\@want),
        'repeated random draws choose the other available quote in exactly two draws');
    (@got,@want) = ((),());
    for my $entry (qw(module facade)) {
        for my $n (2,3,5) {
            for my $initial (0..$n-1) {
                for my $rank (0..$n-2) {
                    my $v = $r->{matrix}{$entry}{$n}{$initial}{$rank};
                    my $alternative = $rank < $initial ? $rank : $rank+1;
                    my $id = $ids[$alternative];
                    my @selects = grep {$_->[0] =~ /SELECT q\.id_quotes.*LIMIT 1 OFFSET \?/s} @{$v->{binds}};
                    push @got, [@$v{qw(return cache sent bounds warnings)},$v->{rows},
                        [map {$_->[-1]} @selects],scalar(@{$v->{sql}})];
                    push @want, [1,{'#test:Alice'=>$id},
                        [['PRIVMSG','#test',"[$id] <Alice> ".$quote_text->($id)]],[0+$n,$n-1],[],
                        $rows->($n),[$initial,$alternative],3];
                }
            }
        }
    }
    $assert->is($json->encode(\@got),$json->encode(\@want),
        'every alternative rank skips the previous row for both entry points, without touching another author or channel');
    (@got,@want) = ((),());
    for my $entry (qw(module facade)) {
        for my $spec (
            ['first',5,35,'Alice','Alice'],['nonrepeat',5,35,'Alice','Alice'],
            ['only_quote',1,10,'Alice','Alice'],['removed_last',3,21,'Alice','Alice'],
            ['prefix',3,35,'Alice','Ali'],['contains',3,21,'xAlicex','Alice'],
            ['underscore',3,21,'Bob_','Bob_'],['percent',3,21,'100%','100%'],
            ['bang',3,21,'a!b','a!b'],['missing',3,undef,'Alice','Missing']) {
            my ($label,$n,$id,$author,$target) = @$spec;
            my $v = $r->{nominal}{$entry}{$label};
            push @got, [@$v{qw(return sent cache bounds warnings)},$v->{rows}];
            push @want, defined($id)
                ? [1,[['PRIVMSG','#test',"[$id] <$author> ".$quote_text->($id)]],
                    {'#test:'.$target=>$id},[0+$n],[],$rows->($n)]
                : [undef,[['NOTICE','Reader','No quotes from Missing on #test.']],{},[],[],$rows->($n)];
        }
        for my $failure (qw(prepare execute empty)) {
            my $v = $r->{failure}{$entry}{$failure};
            push @got, [@$v{qw(return sent cache warnings)},$v->{rows}];
            push @want, [1,[['PRIVMSG','#test','[10] <Alice> '.$quote_text->(10)]],
                {'#test:Alice'=>10},[],[grep {$failure ne 'empty' || $_->[0] != 21} @{$rows->(2)}]];
        }
    }
    $assert->is($json->encode(\@got),$json->encode(\@want),
        'nominal selection, one-row repeats, prefix/fuzzy/escaped matches and SQL-refusal fallback retain their contracts');
};
