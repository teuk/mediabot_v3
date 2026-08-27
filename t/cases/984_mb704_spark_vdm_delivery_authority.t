use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
return sub {
 my($assert)=@_;
 my $rt=do{open my$fh,'<:encoding(UTF-8)',"$Bin/../../Mediabot/VDM/Runtime.pm" or die$!;local$/;<$fh>};
 my $sender=do{open my$fh,'<:encoding(UTF-8)',"$Bin/../../Mediabot/Spark/Sender.pm" or die$!;local$/;<$fh>};
 my $main=do{open my$fh,'<:encoding(UTF-8)',"$Bin/../../mediabot.pl" or die$!;local$/;<$fh>};
 $assert->unlike($rt,qr/SPARK_SEND_ARMED/,'mb704-984: VDM runtime cannot consume Spark master arm itself');
 $assert->like($rt,qr/\$deliver_cb->\(\$picked->\{item\}\)/,'mb704-984: VDM runtime delegates auto delivery instead of owning transport');
 $assert->like($sender,qr/format_vdm_line/,'mb704-984: only guarded Spark sender renders auto VDM output');
 $assert->like($main,qr/_spark_sync_sender_arm\(\$bot, \$sender\)/,'mb704-984: auto VDM path synchronizes master arm before event creation');
 $assert->like($main,qr/\$bot->\{spark_state\}->begin_event\(\s*channel\s*=>\s*\$channel,\s*kind\s*=>\s*'vdm'/s,'mb704-984: VDM becomes visible Spark event state only immediately before guarded send');
 $assert->like($main,qr/attempt_send\(\s*channel\s*=>\s*\$channel,\s*kind\s*=>\s*'vdm'/s,'mb704-984: VDM auto output crosses the same Spark Sender attempt boundary');
};
