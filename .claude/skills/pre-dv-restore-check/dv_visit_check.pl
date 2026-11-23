#!/usr/bin/perl
# dv_visit_check.pl - exhaustive check of the format and depth held for
# leaving Dolby Vision (pre_dv_color_format, pre_dv_max_bpc), over every
# order of client requests up to a bound, with the real request handlers.
# It proves the values held, not the give-back from them (the %pre_dv_back
# branch of webui_apply_config: t/dv_leave_*.t).
# Read SKILL.md next to this file first: property, scope, how to read a result.
#
# Property: while Dolby Vision is on, pre_dv_color_format/pre_dv_max_bpc in
# PGenerator.conf hold the format and depth the conf had just before the
# current DV visit began, when the WebUI began it, and are empty when a
# port 85 client began it (command.pm forget_pre_dv_format_depth comment).
# The self-test's own switches (selftest:1) never change the visit.
# Harm when broken: leaving DV, webui_apply_config gives these values back,
# so the output ends on a format or depth the user never had before DV.
#
# Breadth-first search over conf states. Each step is one whole request run
# through the real code: webui_apply_config (webui.pm) for the WebUI page,
# API clients and the self-test's marked switches; pgenerator_cmd
# (command.pm) for one port 85 SET_PGENERATOR_CONF_<KEY>:<value> command.
# The conf is a real file; the root helper's write is the real
# pgenerator_conf_set_pair (usr/bin/PGenerator_cmd.pl); the in-memory conf
# is reloaded from the file before each request (webui_reload_pgenerator_conf).
#
# Usage: perl dv_visit_check.pl [--tree DIR] [--depth N] [--quiet]
#        perl dv_visit_check.pl --stale [--tree DIR] [--sync COMMIT]
#   --tree   source tree to check (default: the repo this skill is in)
#   --depth  most requests in a sequence (default 5; from 2 on, every
#            request kind must change the conf somewhere, else exit 2)
#   --stale  no search: list the covered functions (SKILL.md "Coverage")
#            whose source differs from the sync commit (SKILL.md)
# Exit 0: property holds (--stale: nothing changed). 1: violation, the
# shortest request sequence is printed (--stale: covered code changed).
# 2: the check itself failed.
use strict;
use warnings;
use threads;
use threads::shared;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long;
use Digest::MD5 qw(md5_hex);

my $here=dirname(File::Spec->rel2abs(__FILE__));
my $tree=File::Spec->catdir($here,"..","..","..");
my $max_states=200000;
my $depth=5;
my $quiet=0;
my $stale=0;
my $sync="";
GetOptions("tree=s"=>\$tree,"depth=i"=>\$depth,"max-states=i"=>\$max_states,"quiet"=>\$quiet,
           "stale"=>\$stale,"sync=s"=>\$sync) or exit 2;
$tree=File::Spec->rel2abs($tree);

# --- --stale: has the covered code changed since the sync commit? -------
sub skill_record {
 open(my $fh,"<","$here/SKILL.md") or do { print STDERR "SKILL.md: $!\n"; exit 2; };
 my $md=do { local $/; <$fh> };
 close($fh);
 my ($commit)=$md=~/^Sync commit: `([0-9a-f]{7,40})`/m;
 my ($section)=$md=~/^## Coverage\n(.*?)(?=^## |\z)/ms;
 my @cover;
 foreach my $line (split(/\n/,$section // "")) {
  next if($line!~/^- `([^`]+)`: (.+)$/);
  my ($file,$list)=($1,$2);
  push(@cover,[$file,[$list=~/`(\@?\w+)`/g]]);
 }
 if(!$commit || !@cover) { print STDERR "SKILL.md has no sync commit or no Coverage list\n"; exit 2; }
 return ($commit,@cover);
}
# A Perl sub or JS function up to its closing brace in column 0, or for
# "@name" a top-level "my @name=( ... );" list.
sub sub_source {
 my ($src,$name)=@_;
 if($name=~/^\@(\w+)$/) { return ($src=~/^(my \@\Q$1\E=\(.*?^\);[ \t]*)$/ms) ? $1 : undef; }
 return ($src=~/^((?:async )?(?:sub|function) \Q$name\E\b.*?^\}[ \t]*)$/ms) ? $1 : undef;
}
if($stale) {
 my ($commit,@cover)=skill_record();
 $commit=$sync if($sync ne "");
 my ($changed,$total)=(0,0);
 foreach my $c (@cover) {
  my ($file,$subs)=@$c;
  open(my $g,"-|","git","-C",$tree,"show","$commit:$file") or do { print STDERR "git show $commit:$file: $!\n"; exit 2; };
  my $old=do { local $/; <$g> } // "";
  close($g);
  if($? != 0 || $old eq "") { print STDERR "git show $commit:$file failed\n"; exit 2; }
  open(my $n,"<","$tree/$file") or do { print STDERR "$tree/$file: $!\n"; exit 2; };
  my $new=do { local $/; <$n> };
  close($n);
  foreach my $s (@$subs) {
   $total++;
   my ($a,$b)=(sub_source($old,$s),sub_source($new,$s));
   if(!defined $a || !defined $b) {
    $changed++;
    print "$file: $s ".(!defined $b ? "is gone from the tree" : "is new since $commit")."\n";
   } elsif($a ne $b) {
    $changed++;
    print "$file: $s changed since $commit\n";
   }
  }
 }
 if($changed) { print "$changed of $total covered functions differ from the sync commit $commit: rerun the check and review the model (SKILL.md).\n"; exit 1; }
 print "All $total covered functions are as at the sync commit $commit.\n";
 exit 0;
}

my $pgdir="$tree/usr/share/PGenerator";
-f "$pgdir/webui.pm" or do { print STDERR "no webui.pm under $tree\n"; exit 2; };

my $tmp=tempdir(CLEANUP=>1);
our ($SELFTEST,@LOG,%VALUES,%DESYNC,%EFFECT);
$SELFTEST=0;

# The root helper's own line editor, taken from the helper as it is.
{
 open(my $fh,"<","$tree/usr/bin/PGenerator_cmd.pl") or do { print STDERR "PGenerator_cmd.pl: $!\n"; exit 2; };
 my $src=do { local $/; <$fh> };
 close($fh);
 my ($sub)=$src=~/^(sub pgenerator_conf_set_pair \(\@\) \{.*?^\})/ms or do { print STDERR "pgenerator_conf_set_pair not found\n"; exit 2; };
 $sub=~s/^sub pgenerator_conf_set_pair /sub set_pair /;
 eval "package RootHelper; no strict; no warnings; $sub; 1" or do { print STDERR "helper: $@\n"; exit 2; };
}

{
 no strict; no warnings;
 unshift(@INC,$pgdir);
 # Before the modules load: webui.pm logs a missing UI asset while it loads.
 *main::log=sub { push(@main::LOG,join(" ",@_)); };
 foreach my $f ("variables.pm","command.pm","webui.pm") {
  my $x=do "$pgdir/$f";
  if(!defined $x && $@) { print STDERR "load $f: $@\n"; exit 2; }
 }
 $main::pattern_conf="$tmp/PGenerator.conf";
 $main::info_dir="$tmp/info";
 mkdir($main::info_dir);
 *main::log=sub { push(@main::LOG,join(" ",@_)); };
 # The root helper: conf writes go to the file through its line editor;
 # everything else (renderer, DRM, network) answers OK and does nothing.
 *main::sudo=sub {
  my ($action,@args)=@_;
  if($action eq "SET_PGENERATOR_CONF" || $action eq "SET_PGENERATOR_CONF_MULTI") {
   my $text="";
   if(open(my $r,"<",$main::pattern_conf)) { local $/; $text=<$r> // ""; close($r); }
   chomp($text);
   for(my $i=0;$i+1<=$#args;$i+=2) { $text=RootHelper::set_pair($text,$args[$i],$args[$i+1] // ""); }
   open(my $w,">",$main::pattern_conf) or return "ERR";
   print $w "$text\n";
   close($w) or return "ERR";
   return "OK";
  }
  return "OK";
 };
 # A self-test post counts as one only while the self-test runs
 # (webui_apply_config: selftest:1, a local request, webui_selftest_running).
 *main::webui_selftest_running=sub { return $main::SELFTEST; };
 *main::webui_renderer_restart_begin=sub { return "rid"; };
 # No calibration software holds the signal: the WebUI may change it.
 *main::webui_signal_owner=sub { return ""; };
 $main::device_model="Raspberry Pi 4 Model B Rev 1.4";
 # No EDID: the signal check judges the TMDS clock against the board only.
 *main::signal_display_caps=sub { return ({known=>0},undef,"HDMI-A-1",""); };
 *main::signal_mode_info=sub {
  return {idx=>"21",width=>1920,height=>1080,interlaced=>0,refresh=>60,clock_khz=>148500,type=>"driver"};
 };
 *main::sync_pattern_bits_default=sub { };
 # renderer_dv_conf_active (command.pm) stays the real one: it is what
 # webui_apply_config judges "in Dolby Vision before" by.
 *main::signal_applied_snapshot_write=sub { };
 *main::signal_refused_clear=sub { };
 *main::pattern_generator_is_running=sub { return 1; };
 *main::renderer_running_conf=sub { return {%main::pgenerator_conf}; };
 $main::calibration_sessions="";
 $main::pitpg_clients=0;
}

# --- conf state --------------------------------------------------------
sub file_text { my $t=""; if(open(my $r,"<",$main::pattern_conf)) { local $/; $t=<$r> // ""; close($r); } return $t; }
sub file_conf { my %c; for(split(/\n/,file_text())) { $c{$1}=$2 if(/^([^=#]+)=(.*)$/); } return \%c; }
sub canon { my $c=shift; return join("\n",map { "$_=$c->{$_}" } sort keys %$c); }
# Each request starts from the conf file alone: process memory outside the
# conf (the WebUI's remembered range) is as after a daemon start.
sub set_state {
 my $text=shift;
 open(my $w,">",$main::pattern_conf) or die "conf: $!";
 print $w "$text\n";
 close($w) or die "conf: $!";
 { no warnings; $main::webui_rgb_quant_range_preferred=""; }
 main::webui_reload_pgenerator_conf();
}
sub dv_on { my $c=shift; return (int($c->{dv_status} || 0) == 1 || int($c->{is_ll_dovi} || 0) == 1 || int($c->{is_std_dovi} || 0) == 1) ? 1 : 0; }

# --- requests ----------------------------------------------------------
# kind: "webui" (a user's or an API client's request: it may begin a visit
# of its own), "selftest" (pgen_selftest.pl apply_config: its scenario or
# restore body with selftest:1), "port85" (one classic-protocol command).
my @actions;
sub webui_req { my ($name,$body,$kind)=@_; push(@actions,{name=>"WebUI ".$name,kind=>$kind || "webui",run=>sub {
 local $main::SELFTEST=(($kind || "") eq "selftest") ? 1 : 0;
 my ($res)=main::webui_apply_config($body,{local=>1});
 return $res;
}}); }
sub port85 { my ($key,$v)=@_; push(@actions,{name=>"port 85 SET_PGENERATOR_CONF_$key:$v",kind=>"port85",run=>sub {
 return main::pgenerator_cmd("SET_PGENERATOR_CONF_$key:$v");
}}); }
# The page posts its whole form by the flags, without signal_mode
# (webui-app.js applySettings; DV values from dvTransportDefaults, the map
# mode the form's first option). API clients name the mode, with or
# without a format and depth.
my $hdr_meta='"max_luma":"1000","min_luma":"0.005","max_cll":"1000","max_fall":"400"';
foreach my $f ("0","1","2") {
 foreach my $b ("8","10") {
  webui_req("page SDR format $f $b-bit",qq({"mode_idx":"21","max_bpc":"$b","color_format":"$f","colorimetry":"2","rgb_quant_range":"1","is_sdr":"1","is_hdr":"0","eotf":"0","primaries":"0","is_ll_dovi":"0","is_std_dovi":"0","dv_status":"0","dv_interface":"0","dv_metadata":"0"}));
  webui_req("page HDR10 format $f $b-bit",qq({"mode_idx":"21","max_bpc":"$b","color_format":"$f","colorimetry":"9","rgb_quant_range":"1","is_sdr":"0","is_hdr":"1","is_ll_dovi":"0","is_std_dovi":"0","dv_status":"0","dv_interface":"0","dv_metadata":"0","eotf":"2","primaries":"2",$hdr_meta}));
 }
}
foreach my $t (["Standard","standard","0","1","0","0","8","2"],["Low Latency","lldv","1","0","1","2","12","1"]) {
 my ($label,$tr,$ll,$std,$if,$f,$b,$q)=@$t;
 webui_req("page $label DV",qq({"mode_idx":"21","max_bpc":"$b","color_format":"$f","colorimetry":"9","rgb_quant_range":"$q","is_sdr":"0","is_hdr":"1","dv_transport":"$tr","is_ll_dovi":"$ll","is_std_dovi":"$std","dv_status":"1","primaries":"1","eotf":"2","dv_interface":"$if","dv_map_mode":"2",$hdr_meta,"dv_color_space":"0","dv_metadata":"4"}));
}
webui_req("API DV by its flags",'{"dv_status":"1","is_std_dovi":"1","is_ll_dovi":"0","dv_transport":"standard"}');
webui_req("API mode only $_",qq({"signal_mode":"$_"})) foreach ("sdr","hdr10","dv");
webui_req("API sdr format 0 8-bit",'{"signal_mode":"sdr","color_format":"0","max_bpc":"8","rgb_quant_range":"1"}');
webui_req("API hdr10 format 1 10-bit",'{"signal_mode":"hdr10","color_format":"1","max_bpc":"10","rgb_quant_range":"1"}');
# pgen_selftest.pl: its scenario configs (@scenarios) and restore_user_state.
webui_req("self-test Standard DV 8-bit",'{"signal_mode":"dv","dv_transport":"standard","max_bpc":"8","selftest":1}',"selftest");
webui_req("self-test Low Latency DV",'{"signal_mode":"dv","dv_transport":"lldv","selftest":1}',"selftest");
webui_req("self-test SDR RGB 8-bit",'{"signal_mode":"sdr","color_format":"0","max_bpc":"8","rgb_quant_range":"1","selftest":1}',"selftest");
webui_req("self-test HDR10 YCbCr 4:4:4 10-bit",'{"signal_mode":"hdr10","color_format":"1","max_bpc":"10","rgb_quant_range":"1","selftest":1}',"selftest");
webui_req("self-test restore Standard DV",'{"signal_mode":"dv","color_format":"0","max_bpc":"8","rgb_quant_range":"2","dv_transport":"standard","selftest":1}',"selftest");
webui_req("self-test restore Low Latency DV",'{"signal_mode":"dv","color_format":"2","max_bpc":"12","rgb_quant_range":"1","dv_transport":"lldv","selftest":1}',"selftest");
port85($_,"0") foreach ("DV_STATUS","IS_LL_DOVI","IS_STD_DOVI");
port85($_,"1") foreach ("DV_STATUS","IS_LL_DOVI","IS_STD_DOVI");
port85("COLOR_FORMAT",$_) foreach ("0","1","2");
port85("MAX_BPC",$_) foreach ("8","10","12");

# --- the visit a state is in (ghost) -----------------------------------
# by: who began the DV visit now on ("webui", "port85", or "" where no
# claim is made: no visit, or one the self-test began); fmt/bpc: what the
# conf held just before it began. A self-test switch never changes the
# visit: the self-test gives the user's settings back itself, and
# webui_apply_config leaves pre_dv_* alone for it (webui.pm, "$selftest").
sub next_visit {
 my ($visit,$kind,$before,$after)=@_;
 my ($was,$now)=(dv_on($before),dv_on($after));
 return $visit if($kind eq "selftest");
 return $visit if($was && $now);
 return {by=>""} if(!$now);
 return {by=>($kind eq "webui" ? "webui" : $kind eq "port85" ? "port85" : ""),
         fmt=>(($before->{color_format} // "") ne "" ? $before->{color_format} : "0"),
         bpc=>(($before->{max_bpc} // "") ne "" ? $before->{max_bpc} : "8")};
}
sub violation {
 my ($visit,$c)=@_;
 return "" if(!dv_on($c));
 my ($f,$b)=($c->{pre_dv_color_format} // "",$c->{pre_dv_max_bpc} // "");
 if($visit->{by} eq "webui" && ($f ne $visit->{fmt} || $b ne $visit->{bpc})) {
  return "the WebUI began this Dolby Vision visit from format $visit->{fmt} $visit->{bpc}-bit, but the conf now holds pre_dv_color_format=\"$f\" pre_dv_max_bpc=\"$b\"";
 }
 if($visit->{by} eq "port85" && ($f ne "" || $b ne "")) {
  return "a port 85 client began this Dolby Vision visit, but the conf still holds pre_dv_color_format=\"$f\" pre_dv_max_bpc=\"$b\" from an earlier one";
 }
 return "";
}
sub vkey { my $v=shift; return join("|",map { $v->{$_} // "" } qw(by fmt bpc)); }

# --- search ------------------------------------------------------------
my $base="port_pattern=85\nmode_idx=21\nsignal_mode=sdr\nis_sdr=1\nis_hdr=0\neotf=0\ncolorimetry=2\nprimaries=0\ndv_status=0\nis_ll_dovi=0\nis_std_dovi=0\ndv_interface=0\ndv_metadata=0\ndv_transport=standard";
my @init=("$base\ncolor_format=0\nmax_bpc=8\nrgb_quant_range=1","$base\ncolor_format=1\nmax_bpc=10\nrgb_quant_range=1");
my (%seen,@queue,%parent);
foreach my $t (@init) {
 set_state($t);
 my $c=file_conf();
 my $k=md5_hex(canon($c))."/".vkey({by=>""});
 next if($seen{$k}++);
 $parent{$k}=[undef,"start: ".join(" ",map { "$_=$c->{$_}" } qw(signal_mode color_format max_bpc))];
 push(@queue,[$k,canon($c),{by=>""},0]);
}
my ($transitions,$desync,$errors,$cut)=(0,0,0,0);
my $found;
my $t0=time();
while(@queue && !$found) {
 my ($k,$text,$visit,$d)=@{shift(@queue)};
 if($d >= $depth) { $cut++; next; }
 foreach my $a (@actions) {
  set_state($text);
  my $before=file_conf();
  @LOG=();
  my $res=eval { $a->{run}->() };
  if($@) { $errors++; print STDERR "error in '$a->{name}': $@" if(!$quiet); next; }
  $transitions++;
  my $after=file_conf();
  $EFFECT{$a->{name}}++ if(canon($after) ne canon($before));
  # Not the property: does the in-memory conf hold what the file holds?
  # An empty value is a deleted key in the file (the helper drops it).
  my %mem=%main::pgenerator_conf;
  my %memset=map { ($_ => $mem{$_}) } grep { defined $mem{$_} && $mem{$_} ne "" } keys %mem;
  if(canon(\%memset) ne canon($after)) {
   $desync++;
   my %u;
   foreach my $key (grep { !$u{$_}++ } (keys %memset,keys %$after)) {
    next if(($memset{$key} // "\x00") eq ($after->{$key} // "\x00"));
    $DESYNC{$key} //= "after '$a->{name}': memory='".($memset{$key} // "")."' file='".($after->{$key} // "")."'";
   }
  }
  my $nv=next_visit($visit,$a->{kind},$before,$after);
  my $nk=md5_hex(canon($after))."/".vkey($nv);
  next if($seen{$nk});
  $seen{$nk}=1;
  $parent{$nk}=[$k,$a->{name}];
  if(my $why=violation($nv,$after)) { $found=[$nk,$why,$after]; last; }
  $VALUES{$_}{$after->{$_}}++ foreach(keys %$after);
  if(scalar(keys %seen) > $max_states) {
   print STDERR "state bound $max_states reached: not exhaustive. Values seen per key:\n";
   foreach my $key (sort { scalar(keys %{$VALUES{$b}}) <=> scalar(keys %{$VALUES{$a}}) } keys %VALUES) {
    print STDERR "  $key: ".join(" ",map { "'$_'" } sort keys %{$VALUES{$key}})."\n";
   }
   exit 2;
  }
  push(@queue,[$nk,canon($after),$nv,$d+1]);
 }
}
my $states=scalar(keys %seen);
my $secs=time()-$t0;
if($found) {
 my ($k,$why,$c)=@$found;
 my @steps;
 while(defined $k) { unshift(@steps,$parent{$k}[1]); $k=$parent{$k}[0]; }
 print "VIOLATION: $why.\n";
 print "Shortest request sequence:\n";
 for(my $i=0;$i<@steps;$i++) { print "  ".($i ? "$i. " : "")."$steps[$i]\n"; }
 print "Conf after it: ".join(" ",map { "$_=".($c->{$_} // "") } qw(signal_mode dv_status is_ll_dovi is_std_dovi color_format max_bpc pre_dv_color_format pre_dv_max_bpc))."\n";
 print "($states states, $transitions requests, ${secs}s)\n";
 exit 1;
}
if($errors) { print "CHECK FAILED: $errors requests died in the handlers (run without --quiet)\n"; exit 2; }
# A request kind that never changed the conf proves nothing: a handler that
# now refuses it (a mock it needs is missing) would leave the check empty.
# From depth 2 on: from the two SDR start confs alone, the port 85 ...:0
# commands and the API's mode-only SDR post have nothing to change.
if($depth < 2) {
 print "Note: depth $depth does not check that every request kind changed the conf (that needs --depth 2 or more).\n";
} elsif(my @idle=grep { !$EFFECT{$_->{name}} } @actions) {
 print "CHECK FAILED: these request kinds never changed the conf, so the search did not exercise them: ".join(", ",map { "'$_->{name}'" } @idle).". Find why the handler refuses them (run one by hand, read its answer) and add what it needs.\n";
 exit 2;
}
if($cut) {
 print "OK up to $depth requests: the property holds in all $states states reachable with at most $depth requests ($transitions requests, ".scalar(@actions)." request kinds, ${secs}s). Not a fixpoint: $cut states at the bound were not expanded.\n";
} else {
 print "OK: the property holds in all $states reachable states, a fixpoint ($transitions requests, ".scalar(@actions)." request kinds, ${secs}s).\n";
}
if($desync) {
 print "Note (not the property): after $desync requests the in-memory conf differed from the file in (until the WebUI next reads the conf; SKILL.md): ".join(", ",sort keys %DESYNC).". First seen:\n";
 print map { "  $_ $DESYNC{$_}\n" } sort keys %DESYNC;
}
exit 0;
