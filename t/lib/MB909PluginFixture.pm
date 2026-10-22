package MB909PluginFixture;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Scalar::Util qw(weaken);
use Mediabot::CommandRegistry;
use Mediabot::PluginManager;

{
    package MB909::Log;
    sub log { 1 }
    package MB909::Bot;
    sub command_registry { $_[0]{registry} }
    sub getUserChannelLevel { 125 }
    package MB909::User;
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'Alice' }
    sub has_level { $_[1] eq 'User' }
    package MB909::Command;
    sub nick { 'Alice_' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub user { bless {},'MB909::User' }
    sub message { bless {},'MB909::Message' }
    sub reply { 1 }
    sub reply_private { 1 }
    package MB909::Service;
    sub _record {
        my ($s,$method,%args)=@_;
        $args{principal}=$args{principal}->snapshot if ref($args{principal});
        push @{$s->{trace}},[$s->{domain},$method,{%args}];
    }
    sub count { my ($s,%a)=@_;$s->_record('count',%a);{ok=>1,count=>3} }
    sub add { my ($s,%a)=@_;$s->_record('add',%a);{ok=>1,status=>'created',id=>41} }
    sub by_keyword { my ($s,%a)=@_;$s->_record('by_keyword',%a);{ok=>1,value=>'definition'} }
    sub upsert { my ($s,%a)=@_;$s->_record('upsert',%a);{ok=>1,status=>'stored'} }
    sub heatmap { my ($s,%a)=@_;$s->_record('heatmap',%a);{ok=>1,days=>[]} }
    sub snapshot { my ($s)=@_;$s->_record('snapshot');{revision=>7,values=>{saved=>'value'}} }
    sub commit { my ($s,%a)=@_;$s->_record('commit',%a);{ok=>1,revision=>8} }
    sub fetch {
        my ($s,$plugin,$request,$callback)=@_;
        $s->_record('fetch',plugin=>$plugin,request=>{%$request});
        $callback->({ok=>1,status=>200,body=>'fixture'});
        return {accepted=>1,request_id=>1};
    }
    sub cancel_plugin { 0 }
}
my $root;
my @caps=qw(http.fetch storage.kv data.quotes.read data.quotes.write data.factoids.read data.factoids.write data.channel_activity.read);
sub _root {
    return $root if $root;
    $root=tempdir('mb909-XXXXXX',TMPDIR=>1,CLEANUP=>1);make_path("$root/service-witness/lib");
    my $manifest={api=>3,name=>'service-witness',version=>'1.0.0',description=>'Service scope test witness',
        runtime=>{kind=>'perl',entrypoint=>'lib/ServiceWitness.pm',class=>'MB909::ServiceWitness'},
        compatibility=>{},activation=>{default=>'off'},capabilities=>\@caps,
        commands=>{capture=>{source=>'public',help=>'Capture a runtime invocation',level=>0,handler=>'capture'}},
        events=>[],jobs=>{},config_schema=>{}};
    open my $mf,'>',"$root/service-witness/plugin.json" or die $!;
    print $mf JSON::PP->new->canonical->encode($manifest);close $mf or die $!;
    open my $pf,'>',"$root/service-witness/lib/ServiceWitness.pm" or die $!;
    print $pf <<'PLUGIN';
package MB909::ServiceWitness;
use strict;use warnings;
our @contexts;
sub new { my ($class,%args)=@_;push @contexts,$args{context};bless {context=>$args{context}},$class }
sub capture { $_[0]{invocation}=$_[2];1 }
1;
PLUGIN
    close $pf or die $!;return $root;
}
sub _service { my ($trace,$domain)=@_;return bless {trace=>$trace,domain=>$domain},'MB909::Service' }
sub _context {
    my ($empty)=@_;my @trace;
    my $bot=bless {registry=>Mediabot::CommandRegistry->new,logger=>bless({},'MB909::Log')},'MB909::Bot';
    my $m=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>_root(),
        v3_http_service=>_service(\@trace,'http'),v3_quote_service=>_service(\@trace,'quote_read'),
        v3_quote_write_service=>_service(\@trace,'quote_write'),v3_factoid_service=>_service(\@trace,'factoid_read'),
        v3_factoid_write_service=>_service(\@trace,'factoid_write'),v3_channel_activity_service=>_service(\@trace,'activity'));
    my $entry=$empty?undef:_load($m,\@trace);
    return ($m,$entry,$bot,\@trace);
}
sub _load {
    my ($m,$trace,$grants)=@_;
    my $entry=$m->load_package_v3('service-witness',grants=>defined($grants)?$grants:\@caps,enable=>1,
        channel_policies=>{'#test'=>{mode=>'on',config=>{}}});
    $m->{v3_repositories}{'service-witness'}=_service($trace,'storage');
    return $entry;
}
sub _capture {
    my ($m,$bot,$entry)=@_;
    $bot->{registry}->handler_for('capture','public')->(bless {},'MB909::Command');
    return $entry->{object}{invocation};
}
sub _ops { return qw(http snapshot commit quote_read quote_write factoid_read factoid_write activity) }
sub _call {
    my ($op,$context,$inv)=@_;
    return $context->http_fetch($inv,{url=>'https://example.net/fixture'},sub {1}) if $op eq 'http';
    return $context->storage_snapshot($inv) if $op eq 'snapshot';
    return $context->storage_commit($inv,expected_revision=>7,set=>{saved=>'next'},delete=>[]) if $op eq 'commit';
    return $context->quote_count($inv) if $op eq 'quote_read';
    return $context->quote_add($inv,'fixture quote') if $op eq 'quote_write';
    return $context->factoid_by_keyword($inv,'spell') if $op eq 'factoid_read';
    return $context->factoid_upsert($inv,'spell','fixture value') if $op eq 'factoid_write';
    return $context->activity_heatmap($inv,'Alice') if $op eq 'activity';
    die 'unknown operation';
}
sub _accepted {
    my ($r)=@_;return ref($r) eq 'HASH' && !$r->{error} && ($r->{ok} || $r->{accepted} || $r->{revision});
}
sub _one {
    my ($case)=@_;my ($m,$old,$bot,$trace)=_context($case eq 'failed_mount_scope');my $ok=0;
    if ($case eq 'retained_scope_release') {
        my $context=$old->{metadata}{plugin_context};my $weak=$old;weaken($weak);
        $m->unregister_plugin('service-witness');undef $old;
        $ok=!defined($weak) && $context->has_capability('storage.kv');
    }
    elsif ($case eq 'failed_mount_scope') {
        $bot->{registry}->register_command(name=>'capture',handler=>sub {1});
        my $loaded=eval {_load($m,$trace);1};
        no warnings 'once';
        my $escaped=$MB909::ServiceWitness::contexts[-1];
        $bot->{registry}->unregister_command('capture','public');
        my $new=_load($m,$trace,[]);my $inv=_capture($m,$bot,$new);
        my $before=@$trace;my $called=eval {_call('quote_write',$escaped,$inv);1};my $error=$@;
        $ok=!$loaded && !$called && $error =~ /service scope is no longer registered/ && @$trace==$before;
    }
    else {
        my $inv=_capture($m,$bot,$old);my $context=$old->{metadata}{plugin_context};
        if ($case eq 'nominal_current') {
            $ok=1;for my $op (_ops()) {$ok &&= _accepted(_call($op,$context,$inv))}
            $ok &&= @$trace==8;
        }
        elsif ($case eq 'disable_enable' || $case eq 'observe') {
            if ($case eq 'disable_enable') {$m->disable('service-witness')}
            else {$m->set_v3_channel_policy('service-witness','#test',mode=>'observe')}
            $ok=1;
            for my $op (_ops()) {
                my $r=_call($op,$context,$inv);
                my $suppressed=$case eq 'disable_enable' || $op =~ /\A(?:commit|quote_write|factoid_write)\z/;
                $ok &&= $suppressed ? ($r->{error} eq ($case eq 'observe'?'observe':'disabled')) : _accepted($r);
            }
            $ok &&= @$trace==($case eq 'observe'?5:0);
            $m->enable('service-witness') if $case eq 'disable_enable';
            if ($case eq 'disable_enable') {
                for my $op (_ops()) {$ok &&= _accepted(_call($op,$context,$inv))}
                $ok &&= @$trace==8;
            }
        }
        else {
            _call($case,$context,$inv);my $before=@$trace;
            $m->unregister_plugin('service-witness');my $new=_load($m,$trace,[]);
            my $new_inv=_capture($m,$bot,$new);$ok=1;
            for my $scoped ($inv,$new_inv) {
                my $called=eval {_call($case,$context,$scoped);1};my $error=$@;
                $ok=0 if $called || $error !~ /service scope is no longer registered/ || @$trace!=$before;
            }
            my $denied=eval {_call($case,$new->{metadata}{plugin_context},$new_inv);1};
            $ok &&= !$denied && $@ =~ /was not granted/ && @$trace==$before;
            $m->unregister_plugin('service-witness');my $fresh=_load($m,$trace);
            my $fresh_inv=_capture($m,$bot,$fresh);
            $ok &&= _accepted(_call($case,$fresh->{metadata}{plugin_context},$fresh_inv)) && @$trace==$before+1;
        }
    }
    $m->unregister_plugin('service-witness');
    return {case=>$case,ok=>$ok?1:0};
}
sub run_contracts {
    return [map {
        my $case=$_;my (@warnings,$result);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$result=eval {_one($case)}}
        my $error=$@;$result||={case=>$case,ok=>0};$result->{ok}=0 if $error || @warnings;
        $result->{error}="$error" if $error;$result->{warnings}=\@warnings if @warnings;$result;
    } (_ops(),qw(nominal_current disable_enable observe failed_mount_scope retained_scope_release))];
}
1;
