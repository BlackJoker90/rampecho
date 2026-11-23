#!/usr/bin/perl
# mutants.pl - shows that dv_visit_check.pl can fail: each mutant breaks the
# covered code in a temp copy of the tree, and the check must catch it
# (exit 1, or 2 where the break leaves the search with nothing to prove).
# The tree itself is never written.
# Usage: perl mutants.pl [--tree DIR] [--depth N]
# Exit 0: every mutant caught. 1: a mutant missed, or its text was not
# found exactly once (SETUP FAILED: the code moved; update the mutant).
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long;

my $here=dirname(File::Spec->rel2abs(__FILE__));
my $tree=File::Spec->catdir($here,"..","..","..");
my $depth=5;
GetOptions("tree=s"=>\$tree,"depth=i"=>\$depth) or exit 2;
$tree=File::Spec->rel2abs($tree);
my $checker="$here/dv_visit_check.pl";
my @files=("usr/share/PGenerator/command.pm","usr/share/PGenerator/webui.pm","usr/bin/PGenerator_cmd.pl");
# [name, file, exact text (must occur once), replacement, exit the check
# must give: 1 (violation) unless named]
my @mutants=(
 ['M0 every WebUI request refused (a handler that lost a mock): the check must not pass','usr/share/PGenerator/webui.pm',
  "sub webui_apply_config (\@) {\n my \$body=shift;\n","sub webui_apply_config (\@) {\n return ('{\"status\":\"error\",\"refused\":true}');\n my \$body=shift;\n",2],
 ['M1 port 85 no longer forgets on DV on (pgenerator_cmd)','usr/share/PGenerator/command.pm',
  '  &forget_pre_dv_format_depth("a port 85 client") if(','  0 && &forget_pre_dv_format_depth("a port 85 client") if('],
 ['M2 self-test switches save and drop pre_dv_* (webui_apply_config guard gone)','usr/share/PGenerator/webui.pm',
  ' if(!$selftest && !grep { exists $posted{$_} } qw(pre_dv_rgb_quant_range',' if(!grep { exists $posted{$_} } qw(pre_dv_rgb_quant_range'],
 ['M3 forget_pre_dv_format_depth never forgets','usr/share/PGenerator/command.pm',
  ' return 0 if(!@held);',' return 0;'],
 ['M4 WebUI no longer saves the format and depth on DV off->on','usr/share/PGenerator/webui.pm',
  '  if(!$dv_before && $dv_after) {','  if(0) {'],
 ['M5 port 85 judges "DV was off" with its own write already in (reordered)','usr/share/PGenerator/command.pm',
  '   my $held=(ref($file_conf) eq "HASH") ? $file_conf : \%pgenerator_conf;',
  '   my $held={%{(ref($file_conf) eq "HASH") ? $file_conf : \%pgenerator_conf},$conf_key=>$conf_value};'],
 ['M6 renderer_dv_conf_active reads dv_status only','usr/share/PGenerator/command.pm',
  "sub renderer_dv_conf_active (\@) {\n","sub renderer_dv_conf_active (\@) {\n return int(\$pgenerator_conf{\"dv_status\"} || 0) == 1 ? 1 : 0;\n"],
);
my $fail=0;
foreach my $m (@mutants) {
 my ($name,$file,$find,$rep,$want)=@$m;
 $want //= 1;
 my $dir=tempdir(CLEANUP=>1);
 make_path("$dir/usr/share","$dir/usr/bin");
 # The whole module directory: webui.pm reads its UI files while it loads.
 system("cp","-R","$tree/usr/share/PGenerator","$dir/usr/share/") == 0 or die "copy failed";
 my $setup_ok=1;
 foreach my $f (@files) {
  open(my $r,"<","$tree/$f") or die "$tree/$f: $!";
  my $src=do { local $/; <$r> };
  close($r);
  if($f eq $file) {
   my ($n,$p)=(0,0);
   while(($p=index($src,$find,$p)) >= 0) { $n++; $p+=length($find); }
   if($n != 1) { print "== $name: SETUP FAILED (text found $n times in $file)\n"; $fail++; $setup_ok=0; last; }
   substr($src,index($src,$find),length($find))=$rep;
  }
  open(my $w,">","$dir/$f") or die "$dir/$f: $!";
  print $w $src;
  close($w) or die "$dir/$f: $!";
 }
 next if(!$setup_ok);
 my $out=`perl "$checker" --tree "$dir" --depth $depth --quiet 2>&1`;
 my $rc=$? >> 8;
 $fail++ if($rc != $want);
 print "== $name: ".(($rc == $want) ? "CAUGHT (exit $rc)" : "MISSED (exit $rc, wanted $want)")."\n";
 print map { "   $_\n" } grep { /\S/ } split(/\n/,$out);
}
exit($fail ? 1 : 0);
