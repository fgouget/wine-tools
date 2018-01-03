# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Shows TestBot statistics
#
# Copyright 2017 Francois Gouget
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

package StatsPage;

use ObjectModel::CGI::Page;
use ObjectModel::Collection;
use WineTestBot::Config;
use WineTestBot::Activity;
use WineTestBot::Log;
use WineTestBot::VMs;

@StatsPage::ISA = qw(ObjectModel::CGI::Page);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->{start} = Time();
  $self->SUPER::_initialize($Request, $RequiredRole);
}

sub _GetDuration($;$)
{
  my ($Secs, $Raw) = @_;

  return "n/a" if (!defined $Secs);

  my @Parts;
  if (!$Raw)
  {
    my $Mins = int($Secs / 60);
    my $Hours = int($Mins / 60);
    my $Days = int($Hours / 24);
    push @Parts, "${Days}d" if ($Days);
    my $Part = $Hours - 24 * $Days;
    push @Parts, "${Part}h" if ($Part);
    $Part = $Mins - 60 * $Hours;
    push @Parts, "${Part}m" if ($Part);
    $Secs = $Secs - 60 * $Mins;
  }
  push @Parts, (@Parts or int($Secs) == $Secs) ?
               int($Secs) ."s" :
               sprintf('%.1fs', $Secs);
  return join(" ", @Parts);
}

sub _CompareVMs()
{
  my ($aHost, $bHost) = ($a->GetHost(), $b->GetHost());
  if ($PrettyHostNames)
  {
    $aHost = $PrettyHostNames->{$aHost} || $aHost;
    $bHost = $PrettyHostNames->{$bHost} || $bHost;
  }
  return $aHost cmp $bHost || $a->Name cmp $b->Name;
}

sub _AddRate($$;$)
{
  my ($Stats, $StatKey, $AllStats) = @_;

  my $RateKey = $StatKey;
  $RateKey =~ s/(?:\.time)?\.count$/.rate/;
  $AllStats ||= $Stats;
  $Stats->{$RateKey} = $AllStats->{elapsed} ?
        3600 * $Stats->{$StatKey} / $AllStats->{elapsed} :
      "n/a";
}

sub _GetAverage($$)
{
  my ($Stats, $Key) = @_;
  return "n/a" if (!$Stats->{"$Key.count"});
  return $Stats->{$Key} / $Stats->{"$Key.count"};
}

my $NO_AVERAGE = 1;
my $NO_PERCENTAGE = 2;
my $NO_TIME = 4;

sub _GetStatStr($$;$$)
{
  my ($Stats, $StatKey, $AllStats, $Flags) = @_;

  if ($StatKey =~ /\.time$/ and !($Flags & $NO_AVERAGE) and
      exists $Stats->{"$StatKey.count"})
  {
    my $Avg = _GetAverage($Stats, $StatKey);
    return $Avg eq "n/a" ? "n/a" : _GetDuration($Avg, $Flags & $NO_TIME);
  }

  if ($StatKey =~ /\.size$/ and !($Flags & $NO_AVERAGE) and
      exists $Stats->{"$StatKey.count"})
  {
    my $Avg = _GetAverage($Stats, $StatKey);
    return $Avg eq "n/a" ? "n/a" : int($Avg);
  }

  my $Value = $Stats->{$StatKey};
  if ($StatKey =~ /\.elapsed$/ and !($Flags & $NO_PERCENTAGE))
  {
    $AllStats ||= $Stats;
    return "n/a" if (!$AllStats->{elapsed});
    return sprintf('%.1f%', 100 * $Value / $AllStats->{elapsed});
  }
  if ($StatKey =~ /(?:\belapsed|\.time(?!\.count))/)
  {
    return _GetDuration($Value, $Flags & $NO_TIME);
  }
  if ($StatKey =~ /\.rate$/)
  {
    return sprintf('%.1f / h', $Value);
  }
  return "0" if (!exists $Stats->{$StatKey});
  return $Value if ($Value == int($Value));
  return sprintf('%.1f', $Value);
}

sub _GetStatHtml($$;$$)
{
  my ($Stats, $StatKey, $AllStats, $Flags) = @_;

  my $Value = _GetStatStr($Stats, $StatKey, $AllStats, $Flags);
  return $Value if (!$Stats->{"$StatKey.source"});

  my $SrcObj = $Stats->{"$StatKey.source"};
  my ($JobId, $StepNo, $TaskNo) = ObjectModel::Collection::SplitKey(undef, $SrcObj->GetFullKey());
  if (defined $TaskNo)
  {
    my $Key = "$JobId#k". ($StepNo * 100 + $TaskNo);
    return "<a href='/JobDetails.pl?Key=$Key'>$Value</a>";
  }
  return "<a href='/index.pl#job$JobId'>$Value</a>";
}

sub _GenGlobalLine($$$;$$)
{
  my ($Stats, $StatKey, $Label, $Description, $Flags) = @_;

  my $Value = _GetStatHtml($Stats, $StatKey, undef, $Flags);
  print "<tr><td>$Label</td><td>$Value</td><td>$Description</td></tr>\n";
}

sub _GenStatsLine($$$$;$)
{
  my ($RowStats, $StatKey, $Label, $ColumnKeys, $Flags) = @_;

  print "<tr><td>$Label</td>\n";
  foreach my $Col (@$ColumnKeys)
  {
    my $Stats = $RowStats->{items}->{$Col};
    my $Value = _GetStatHtml($Stats, $StatKey, $RowStats, $Flags);
    print "<td>$Value</td>\n";
  }
  print "</tr>\n";
}

sub GenerateBody($)
{
  my ($self) = @_;

  print "<h1>${ProjectName} Test Bot activity statistics</h1>\n";
  print "<div class='Content'>\n";

  ### Get the sorted VMs list

  my $VMs = CreateVMs();
  $VMs->FilterEnabledRole();
  my @SortedVMs = sort _CompareVMs @{$VMs->GetItems()};
  my $Stats = GetStatistics($VMs);

  ### Show global statistics

  my $GlobalStats = $Stats->{global};
  print "<h2>General statistics</h2>\n";
  print "<div class='CollectionBlock'><table>\n";

  print "<thead><tr><th>Stat</th><th>Value</th><th>Description</th></thead>\n";
  print "<tbody>\n";

  _GenGlobalLine($GlobalStats, "elapsed", "Job history", "How far back the job history goes.");

  _GenGlobalLine($GlobalStats, "jobs.count", "Job count", "The number of jobs in the job history.");
  _AddRate($GlobalStats, "jobs.count");
  _GenGlobalLine($GlobalStats, "jobs.rate", "Job rate", "How fast new jobs are coming in.");
  _GenGlobalLine($GlobalStats, "tasks.count", "Task count", "The number of tasks.");
  _AddRate($GlobalStats, "tasks.count");
  _GenGlobalLine($GlobalStats, "tasks.rate", "Task rate", "How fast new tasks are coming in.");
  _GenGlobalLine($GlobalStats, "busy.elapsed", "Busy time", "How much wall clock time was spent running jobs.", $NO_PERCENTAGE);
  _GenGlobalLine($GlobalStats, "busy.elapsed", "Busy \%", "The percentage of wall clock time where the TestBot was busy running jobs.");

  print "<tr><td class='StatSeparator'>Job times</td><td colspan='2'><hr></td></tr>\n";
  _GenGlobalLine($GlobalStats, "jobs.time.p10", "10%", "10% of the jobs completed within this time.");
  _GenGlobalLine($GlobalStats, "jobs.time.p50", "50%", "50% of the jobs completed within this time.");
  _GenGlobalLine($GlobalStats, "jobs.time.p90", "90%", "90% of the jobs completed within this time.");
  _GenGlobalLine($GlobalStats, "jobs.time.max", "Max", "The slowest job took this long. Note that this is heavily influenced by test storms.");

  print "<tr><td class='StatSeparator'>Average times</td><td colspan='2'><hr></td></tr>\n";
  _GenGlobalLine($GlobalStats, "jobs.time", "Job completion", "How long it takes to complete a  regular job (excluding canceled ones). Note that this is heavily influenced by test storms.");
  _GenGlobalLine($GlobalStats, "reconfig.time", "Wine update", "How long the daily Wine update takes.");
  _GenGlobalLine($GlobalStats, "suite.time", "WineTest", "Average time for a WineTest run.");
  _GenGlobalLine($GlobalStats, "build.time", "Build", "Average patch build time.");
  _GenGlobalLine($GlobalStats, "single.time", "Test", "Average test run time. Note that this very much depends on the tests and how many time out on a given day.");

  print "<tr><td class='StatSeparator'>WineTest reports</td><td colspan='2'><hr></td></tr>\n";
  _GenGlobalLine($GlobalStats, "suite.size", "Average size", "Average WineTest report size.");
  _GenGlobalLine($GlobalStats, "suite.size.max", "Max size", "Maximum WineTest report size.");

  print "<tr><td class='StatSeparator'>Errors</td><td colspan='2'><hr></td></tr>\n";
  _GenGlobalLine($GlobalStats, "timeout.count", "Timeouts", "How many timeouts occurred, either because of a test bug or a TestBot performance issue.");
  _GenGlobalLine($GlobalStats, "boterror.count", "TestBot errors", "How many tasks failed due to a TestBot error.");
  _GenGlobalLine($GlobalStats, "error.count", "Transient errors", "How many transient (network?) errors happened and caused the task to be re-run.");

  print "<tr><td class='StatSeparator'>Activity</td><td colspan='2'><hr></td></tr>\n";
  my $VMsStats = $Stats->{vms};
  _GenGlobalLine($VMsStats, "elapsed", "Activity history", "How far the activity records go. This is used for the VM and VM host tables.");
  _GenGlobalLine($GlobalStats, "records.count", "Record count", "The number of activity records.");

  print "</tbody></table></div>\n";

  ### Generate a table with the VM host statistics

  print "<p></p>\n";
  print "<h2>VM host statistics</h2>\n";
  print "<div class='CollectionBlock'><table>\n";

  print "<thead><tr><th>Stat</th>\n";
  my $HostsStats = $Stats->{hosts};
  my $SortedHosts = [ sort keys %{$Stats->{hosts}->{items}} ];
  foreach my $Host (@$SortedHosts)
  {
    my $DisplayHost = $Host;
    if ($PrettyHostNames and defined $PrettyHostNames->{$Host})
    {
      $DisplayHost = $PrettyHostNames->{$Host};
    }
    $DisplayHost ||= "localhost";
    print "<th>$DisplayHost</th>\n";

    _AddRate($HostsStats->{items}->{$Host}, "reverting.time.count", $HostsStats);
    _AddRate($HostsStats->{items}->{$Host}, "running.time.count", $HostsStats);
  }
  print "</tr></thead>\n";

  print "<tbody>\n";
  _GenStatsLine($HostsStats, "reverting.time.count", "Revert count", $SortedHosts);
  _GenStatsLine($HostsStats, "reverting.rate", "Revert rate", $SortedHosts);
  _GenStatsLine($HostsStats, "running.time.count", "Task count", $SortedHosts);
  _GenStatsLine($HostsStats, "running.rate", "Task rate", $SortedHosts);
  _GenStatsLine($HostsStats, "busy.elapsed", "Busy time", $SortedHosts, $NO_PERCENTAGE);
  _GenStatsLine($HostsStats, "busy.elapsed", "Busy \%", $SortedHosts);

  print "<tr><td class='StatSeparator'>Average times</td><td colspan='", scalar(@$SortedHosts),"'><hr></td></tr>\n";
  _GenStatsLine($HostsStats, "reverting.time", "Revert", $SortedHosts);
  _GenStatsLine($HostsStats, "sleeping.time", "Sleep", $SortedHosts);
  _GenStatsLine($HostsStats, "running.time", "Run", $SortedHosts);
  _GenStatsLine($HostsStats, "dirty.time", "Dirty", $SortedHosts);
  _GenStatsLine($HostsStats, "offline.time", "Offline", $SortedHosts);
  _GenStatsLine($HostsStats, "suite.time", "WineTest", $SortedHosts);

  print "<tr><td class='StatSeparator'>Maximum times</td><td colspan='", scalar(@$SortedHosts),"'><hr></td></tr>\n";
  _GenStatsLine($HostsStats, "reverting.time.max", "Revert", $SortedHosts);
  _GenStatsLine($HostsStats, "sleeping.time.max", "Sleep", $SortedHosts);
  _GenStatsLine($HostsStats, "running.time.max", "Run", $SortedHosts);
  _GenStatsLine($HostsStats, "dirty.time.max", "Dirty", $SortedHosts);
  _GenStatsLine($HostsStats, "offline.time.max", "Offline", $SortedHosts);
  _GenStatsLine($HostsStats, "suite.time.max", "WineTest", $SortedHosts);

  print "<tr><td class='StatSeparator'>Errors</td><td colspan='", scalar(@$SortedHosts),"'><hr></td></tr>\n";
  _GenStatsLine($HostsStats, "timeout.count", "Timeouts", $SortedHosts);
  _GenStatsLine($HostsStats, "boterror.count", "TestBot errors", $SortedHosts);
  _GenStatsLine($HostsStats, "error.count", "Transient errors", $SortedHosts);

  print "</tbody></table></div>\n";

  ### Generate a table with the VM statistics

  print "<p></p>\n";
  print "<h2>VM statistics</h2>\n";
  print "<div class='CollectionBlock'><table>\n";

  print "<thead><tr><th>Stat</th>\n";
  my $SortedVMKeys;
  foreach my $VM (@SortedVMs)
  {
    my $Host = $VM->GetHost();
    if ($PrettyHostNames and defined $PrettyHostNames->{$Host})
    {
      $Host = $PrettyHostNames->{$Host};
    }
    $Host = " on $Host" if ($Host ne "");
    print "<th>", $VM->Name, "$Host</th>\n";
    push @$SortedVMKeys, $VM->Name;

    _AddRate($VMsStats->{items}->{$VM->Name}, "reverting.time.count", $VMsStats);
    _AddRate($VMsStats->{items}->{$VM->Name}, "running.time.count", $VMsStats);
  }
  print "</tr></thead>\n";

  print "<tbody>\n";
  _GenStatsLine($VMsStats, "reverting.time.count", "Revert count", $SortedVMKeys);
  _GenStatsLine($VMsStats, "reverting.rate", "Revert rate", $SortedVMKeys);
  _GenStatsLine($VMsStats, "running.time.count", "Task count", $SortedVMKeys);
  _GenStatsLine($VMsStats, "running.rate", "Task rate", $SortedVMKeys);
  _GenStatsLine($VMsStats, "busy.elapsed", "Busy time", $SortedVMKeys, $NO_PERCENTAGE);
  _GenStatsLine($VMsStats, "busy.elapsed", "Busy \%", $SortedVMKeys);

  print "<tr><td class='StatSeparator'>Average times</td><td colspan='", scalar(@$SortedVMKeys),"'><hr></td></tr>\n";
  _GenStatsLine($VMsStats, "reverting.time", "Revert", $SortedVMKeys);
  _GenStatsLine($VMsStats, "sleeping.time", "Sleep", $SortedVMKeys);
  _GenStatsLine($VMsStats, "running.time", "Run", $SortedVMKeys);
  _GenStatsLine($VMsStats, "dirty.time", "Dirty", $SortedVMKeys);
  _GenStatsLine($VMsStats, "offline.time", "Offline", $SortedVMKeys);
  _GenStatsLine($VMsStats, "suite.time", "WineTest", $SortedVMKeys);

  print "<tr><td class='StatSeparator'>Maximum times</td><td colspan='", scalar(@$SortedVMKeys),"'><hr></td></tr>\n";
  _GenStatsLine($VMsStats, "reverting.time.max", "Revert", $SortedVMKeys);
  _GenStatsLine($VMsStats, "sleeping.time.max", "Sleep", $SortedVMKeys);
  _GenStatsLine($VMsStats, "running.time.max", "Run", $SortedVMKeys);
  _GenStatsLine($VMsStats, "dirty.time.max", "Dirty", $SortedVMKeys);
  _GenStatsLine($VMsStats, "offline.time.max", "Offline", $SortedVMKeys);
  _GenStatsLine($VMsStats, "suite.time.max", "WineTest", $SortedVMKeys);

  print "<tr><td class='StatSeparator'>WineTest/Reconfig reports</td><td colspan='", scalar(@$SortedVMKeys),"'><hr></td></tr>\n";
  _GenStatsLine($VMsStats, "report.size", "Average size", $SortedVMKeys);
  _GenStatsLine($VMsStats, "report.size.max", "Max size", $SortedVMKeys);

  print "<tr><td class='StatSeparator'>Errors</td><td colspan='", scalar(@$SortedVMKeys),"'><hr></td></tr>\n";
  _GenStatsLine($VMsStats, "timeout.count", "Timeouts", $SortedVMKeys);
  _GenStatsLine($VMsStats, "boterror.count", "TestBot errors", $SortedVMKeys);
  _GenStatsLine($VMsStats, "error.count", "Transient errors", $SortedVMKeys);

  print "</tbody></table></div>\n";
  print "<p class='GeneralFooterText'>Generated in ", Elapsed($self->{start}), " s</p>\n";
}

package main;

my $Request = shift;

my $StatsPage = StatsPage->new($Request, "wine-devel");
$StatsPage->GeneratePage();
