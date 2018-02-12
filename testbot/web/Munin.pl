# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# A server-side module to allow monitoring the TestBot from Munin.
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

use WineTestBot::Config;
use WineTestBot::Activity;
use WineTestBot::VMs;

# This matches the 'new' palette's colors.
my @LineColors = (
  "00cc00", # COLOUR0 hsl(120, 100%, 40%)
  "0065b3", # COLOUR1 hsl(206, 100%, 35%)
  "ff8000", # COLOUR2 hsl( 30, 100%, 50%)
  "ffcc00", # COLOUR3 hsl( 48, 100%, 50%)
  "330099", # COLOUR4 hsl(260, 100%, 30%)
  "990099", # COLOUR5 hsl(300, 100%, 30%)
  "ccff00", # COLOUR6 hsl( 72, 100%, 50%)
  "ff0000", # COLOUR7 hsl(  0, 100%, 50%)
  "808080", # COLOUR8 hsl(  0,   0%, 50%)
);

# Use the same colors as for the lines so the related area and lines are easy
# to match, but bring the lightness to 85% so the lines can be seen on top of
# the area.
my @AreaColors = (
  "b3ffb3", # hsl(120, 100%, 85%)
  "b3deff", # hsl(206, 100%, 85%)
  "ffd9b3", # hsl( 30, 100%, 85%)
  "fff0b3", # hsl( 48, 100%, 85%)
  "ccb3ff", # hsl(260, 100%, 85%)
  "ffb3ff", # hsl(300, 100%, 85%)
  "f0ffb3", # hsl( 72, 100%, 85%)
  "ffb3b3", # hsl(  0, 100%, 85%)
  "d9d9d9", # hsl(  0,   0%, 85%)
);

sub _CleanFieldName($)
{
  my ($Name) = @_;

  $Name =~ s/^[^A-Za-z_]+/_/;
  $Name =~ s/[^A-Za-z0-9_]/_/g;
  return $Name;
}

sub _GetAverage($$;$)
{
  my ($Stats, $Key, $Scale) = @_;
  return "U" if (!$Stats->{"$Key.count"});
  return $Stats->{$Key} / $Stats->{"$Key.count"} / ($Scale || 1);
}

=pod
=over 12

=item C<GetOutput()>

Analyses the activity of the recent past, computes the corresponding metrics
to be tracked by Munin, and prints the Munin configuration and data on stdout.

Note that defining how far back to go to compute the Munin metrics is tricky.

Munin collects data every 5 minutes so if can be tempting to report on what
happened in the past 5 minutes. However we have to report on infrequent events:
- New jobs arrive infrequently: around one per hour currently, and it is
  not rare for two of them to arrive at the same time. If we were to naively
  extrapolate 1 new job in the past 5 minutes as a rate of 12 jobs per hour
  we'd get a graph with exagerated swings. But note that things would converge
  on a meaningful value as Munin averages things out for the monthly or yearly
  graphs.
- We could instead record when the last job arrived and derive a rate by
  dividing the number of new jobs by that interval. For instance assume the
  rate is 4 jobs/hour, at precisely 15 minutes intervals. So over the course
  of an hour we will report a rate of 4 jobs/hour 4 times, each time the
  result of 1 / 15 * 60, and a rate of 0 the 9 other times. But when Munin then
  goes on to average these, for instance for the monthly graph, it will get
  an hourly rate of 1.3 job/hour = (4*4 + 9*0) / 12, which is wrong.
- Another approach to the above problem would be to not graph a rate but
  simply the number of new jobs in the given period. However the rate is much
  more meaningful. 4 jobs/hour means the TestBot must complete jobs in under
  15 minutes to keep up. But figuring out the rate from a graph of the raw new
  job count would be quite a bit harder for the administrator.
- For the VM operation times (like revert times), chances are that over a
  5 minutes period there is nothing to report, so the value is 'undefined',
  'U'. This results in dashed lines: one short dash for a 5 minutes period and
  then nothing for the next hour. The shorter the period, the shorter and more
  widely spaced the dashes, making the graph hard to read.
- When no data is available in the chosen period, we could also report the
  last value for that operation. For instance if a revert took 15 seconds,
  report 15 seconds until a new revert occurs, thus avoiding the dashed line
  issue. However how long should the last value be reported? Also seeing a
  continuous line for the offline time one could think it means the VM is
  frequently being marked offline.

Taking all this into account, GetOutput() analyzes the past hour.
- This gives meaningful hourly rates.
- And where there are intermittent values the dashes are long enough.

=back
=cut

sub GetOutput($)
{
  my ($Request) = @_;

  # Return a text file
  $Request->content_type("text/plain");

  # Analyze what happened in the past hour
  my $Period = 60;
  my $PeriodLabel = "1 hour";

  my $VMs = CreateVMs();
  $VMs->FilterEnabledRole();
  my $Stats = GetStatistics($VMs, $Period * 60);

  my @SortedHosts = sort keys %{$Stats->{hosts}->{items}};
  print sorted keys %{$Stats->{hosts}->{items}}, "\n";
  my %HostDisplayNames;
  foreach my $Host (@SortedHosts)
  {
    my $DisplayHost = $Host;
    if ($PrettyHostNames and defined $PrettyHostNames->{$Host})
    {
      $DisplayHost = $PrettyHostNames->{$Host};
    }
    $HostDisplayNames{$Host} = $DisplayHost || "localhost";
  }

  # Just do a plain VM sort independently of their VM host
  my @SortedVMs = sort { $a->Name cmp $b->Name } @{$VMs->GetItems()};

  # Print the configuration information
  print "===== config =====\n";
  my @Data;

  ### Generate a graph of the global job & task rates
  print "multigraph global_rates\n";
  push @Data, "multigraph global_rates\n";

  # Config
  print "graph_title 1. Global job and task rates\n";
  print "graph_category Wine TestBot\n";
  print "graph_vlabel per hour\n";
  print "graph_info Shows the rate at which new jobs and tasks are created and completed globally (based on the past $PeriodLabel).\n";
  print "\n";

  # Global fields
  print "newjobrate.label New jobs\n";
  print "newjobrate.type GAUGE\n";
  print "newjobrate.draw LINE1\n";
  print "newjobrate.min 0\n";
  my $Value = ($Stats->{global}->{"newjobs.count"} || 0) * 60 / $Period;
  push @Data, "newjobrate.value $Value\n";

  print "donejobrate.label Completed jobs\n";
  print "donejobrate.type GAUGE\n";
  print "donejobrate.draw LINE1\n";
  print "donejobrate.min 0\n";
  $Value = ($Stats->{global}->{"donejobs.count"} || 0) * 60 / $Period;
  push @Data, "donejobrate.value $Value\n";

  print "newtaskrate.label New tasks\n";
  print "newtaskrate.type GAUGE\n";
  print "newtaskrate.draw LINE1\n";
  print "newtaskrate.min 0\n";
  $Value = ($Stats->{global}->{"newtasks.count"} || 0) * 60 / $Period;
  push @Data, "newtaskrate.value $Value\n";

  print "donetaskrate.label Completed tasks\n";
  print "donetaskrate.type GAUGE\n";
  print "donetaskrate.draw LINE1\n";
  print "donetaskrate.min 0\n";
  $Value = ($Stats->{global}->{"donetasks.count"} || 0) * 60 / $Period;
  push @Data, "donetaskrate.value $Value\n";

  print "\n";
  push @Data, "\n";


  ### Generate a graph of the per VM host task rates
  print "multigraph vmhost_rates\n";
  push @Data, "multigraph vmhost_rates\n";

  # Config
  print "graph_title 2. VM host task completion rates\n";
  print "graph_category Wine TestBot\n";
  print "graph_vlabel per hour\n";
  print "graph_info Shows the rate at which tasks were completed per VM host (based on the past $PeriodLabel).\n";

  # Provide the task creation rates as a backdrop
  my $HostsStats = $Stats->{hosts}->{items};
  my ($Index, $Draw, $Stacked) = (0, "AREA", "");
  foreach my $Host (@SortedHosts)
  {
    my $DisplayName = $HostDisplayNames{$Host};
    my $SHost = _CleanFieldName($DisplayName);

    print "${SHost}_newtaskrate.label New tasks on $DisplayName$Stacked\n";
    print "${SHost}_newtaskrate.type GAUGE\n";
    print "${SHost}_newtaskrate.draw $Draw\n";
    print "${SHost}_newtaskrate.colour $AreaColors[$Index]\n" if ($AreaColors[$Index]);
    print "${SHost}_newtaskrate.min 0\n";
    $Value = ($HostsStats->{$Host}->{"newtasks.count"} || 0) * 60 / $Period;
    push @Data, "${SHost}_newtaskrate.value $Value\n";
    ($Draw, $Stacked) = ("STACK", " (stacked)");
    $Index++;
  }

  $Index = 0;
  foreach my $Host (@SortedHosts)
  {
    my $DisplayName = $HostDisplayNames{$Host};
    my $SHost = _CleanFieldName($DisplayName);

    print "${SHost}_donetaskrate.label Completed tasks on $DisplayName\n";
    print "${SHost}_donetaskrate.type GAUGE\n";
    print "${SHost}_donetaskrate.draw LINE1\n";
    print "${SHost}_donetaskrate.colour $LineColors[$Index]\n" if ($LineColors[$Index]);
    print "${SHost}_donetaskrate.min 0\n";
    $Value = ($HostsStats->{$Host}->{"donetasks.count"} || 0) * 60 / $Period;
    push @Data, "${SHost}_donetaskrate.value $Value\n";
    $Index++;
  }

  print "\n";
  push @Data, "\n";


  ### Generate a graph of the global & per-host busy percentage
  print "multigraph busy\n";
  push @Data, "multigraph busy\n";

  # Config
  print "graph_title 3. TestBot Utilization\n";
  print "graph_category Wine TestBot\n";
  print "graph_args --base 1000 --lower-limit 0 --upper-limit 100 --rigid\n";
  print "graph_vlabel % busy\n";
  print "graph_info Shows how busy the TestBot was globally and per VM host over the past $PeriodLabel.\n";
  print "\n";

  # Global fields
  print "globalbusy.label Global utilization rate\n";
  print "globalbusy.type GAUGE\n";
  print "globalbusy.draw LINE2\n";
  print "globalbusy.min 0\n";
  $Value = 100 * ($Stats->{global}->{"busy.elapsed"} || 0) / $Period / 60;
  push @Data, "globalbusy.value $Value\n";

  # Per-host fields
  foreach my $Host (@SortedHosts)
  {
    my $DisplayName = $HostDisplayNames{$Host};
    my $SHost = _CleanFieldName($DisplayName);
    print "${SHost}_busy.label $DisplayName utilization rate\n";
    print "${SHost}_busy.type GAUGE\n";
    print "${SHost}_busy.draw LINE1\n";
    print "${SHost}_busy.min 0\n";
    $Value = 100 * ($HostsStats->{$Host}->{"busy.elapsed"} || 0) / $Period / 60;
    push @Data, "${SHost}_busy.value $Value\n";
  }

  print "\n";
  push @Data, "\n";


  ### Generate a graph of the average job completion time
  print "multigraph job_times\n";
  push @Data, "multigraph job_times\n";

  # Config
  print "graph_title 4. Job completion time\n";
  print "graph_category Wine TestBot\n";
  print "graph_vlabel minutes\n";
  print "graph_info Shows the average job completion time.\n";
  print "\n";

  # Fields
  print "avgjobtime.label $PeriodLabel average\n";
  print "avgjobtime.type GAUGE\n";
  print "avgjobtime.draw LINE1\n";
  print "avgjobtime.min 0\n";
  $Value = _GetAverage($Stats->{global}, "jobs.time", 60);
  push @Data, "avgjobtime.value $Value\n";

  print "\n";
  push @Data, "\n";


  ### For each VM generate a graph of the revert, sleep, dirty and offline
  ### times
  foreach my $VM (@SortedVMs)
  {
    my $MultiGraph = "vm_times_". _CleanFieldName($VM->Name);
    my $VMStats = $Stats->{vms}->{items}->{$VM->Name};

    # Config
    print "multigraph $MultiGraph\n";
    push @Data, "multigraph $MultiGraph\n";

    print "graph_title 5. VM operation times for ", $VM->Name, "\n";
    print "graph_category Wine TestBot\n";
    print "graph_vlabel seconds\n";
    print "graph_info Shows the $PeriodLabel average times for the VM operations. Note that the sleep time includes booting if the VM was powered off, and the run time includes sending the test executable and retrieving the test results. Also the run time excludes data from the WineTest and Wine Update tasks.\n";
    print "\n";

    # Fields
    foreach my $FieldParams (["reverting", "Revert"],
                             ["sleeping", "Sleep"],
                             ["dirty", "Dirty"],
                             ["offline", "Offline"])
    {
      my ($Field, $Label) = @$FieldParams;
      print "avg$Field.label $Label time\n";
      print "avg$Field.type GAUGE\n";
      print "avg$Field.draw LINE2\n";
      print "avg$Field.min 0\n";
      $Value = _GetAverage($VMStats, "$Field.time");
      push @Data, "avg$Field.value $Value\n";
    }

    print "\n";
    push @Data, "\n";
  }


  ### Generate a graph of the VM errors
  print "multigraph vm_errors\n";
  push @Data, "multigraph vm_errors\n";

  # Config
  print "graph_title 6. VM errors\n";
  print "graph_category Wine TestBot\n";
  print "graph_vlabel count\n";
  print "graph_info Shows the number of TestBot and other task errors for each VM in the past $PeriodLabel.\n";
  print "\n";

  # Per-host fields
  ($Index, $Draw, $Stacked) = (0, "AREA", "");
  foreach my $VM (@SortedVMs)
  {
    my $SName = _CleanFieldName($VM->Name);
    my $VMStats = $Stats->{vms}->{items}->{$VM->Name};

    print "${SName}_boterrors.label ". $VM->Name ." TestBot errors$Stacked\n";
    print "${SName}_boterrors.type GAUGE\n";
    print "${SName}_boterrors.draw $Draw\n";
    print "${SName}_boterrors.colour $AreaColors[$Index]\n" if ($AreaColors[$Index]);
    print "${SName}_boterrors.min 0\n";
    $Value = $VMStats->{"boterror.count"} || 0;
    push @Data, "${SName}_boterrors.value $Value\n";
    ($Draw, $Stacked) = ("STACK", " (stacked)");
    $Index++;
  }

  ($Index, $Draw, $Stacked) = (0, "LINE1", "");
  foreach my $VM (@SortedVMs)
  {
    my $SName = _CleanFieldName($VM->Name);
    my $VMStats = $Stats->{vms}->{items}->{$VM->Name};

    print "${SName}_errors.label ". $VM->Name ." other errors$Stacked\n";
    print "${SName}_errors.type GAUGE\n";
    print "${SName}_errors.draw $Draw\n";
    print "${SName}_errors.colour $LineColors[$Index]\n" if ($LineColors[$Index]);
    print "${SName}_errors.min 0\n";
    $Value = $VMStats->{"error.count"} || 0;
    push @Data, "${SName}_errors.value $Value\n";
    ($Draw, $Stacked) = ("STACK", " (stacked)");
    $Index++;
  }

  print "\n";
  push @Data, "\n";


  ### Generate a graph of the WineTest and Reconfig times
  print "multigraph test_times\n";
  push @Data, "multigraph test_times\n";

  # Config
  print "graph_title 7. WineTest and Reconfig times\n";
  print "graph_category Wine TestBot\n";
  print "graph_vlabel minutes\n";
  print "graph_info Shows the average time the VMs took to complete the WineTest and Reconfig tasks in the past $PeriodLabel.\n";
  print "\n";

  # Fields
  print "avgwinetesttime.label WineTest time\n";
  print "avgwinetesttime.type GAUGE\n";
  print "avgwinetesttime.draw LINE1\n";
  print "avgwinetesttime.min 0\n";
  $Value = _GetAverage($Stats->{global}, "suite.time", 60);
  push @Data, "avgwinetesttime.value $Value\n";

  print "avgreconfigtime.label Reconfig time\n";
  print "avgreconfigtime.type GAUGE\n";
  print "avgreconfigtime.draw LINE1\n";
  print "avgreconfigtime.min 0\n";
  $Value = _GetAverage($Stats->{global}, "reconfig.time", 60);
  push @Data, "avgreconfigtime.value $Value\n";

  print "\n";
  push @Data, "\n";


  ### Generate a graph of the average and maximum WineTest report size
  print "multigraph report_sizes\n";
  push @Data, "multigraph report_sizes\n";

  # Config
  print "graph_title 8. WineTest report sizes\n";
  print "graph_category Wine TestBot\n";
  print "graph_args --base 1024\n";
  print "graph_vlabel bytes\n";
  print "graph_info Shows the average and maximum sizes across VMs for the latest WineTest reports.\n";
  print "\n";

  # Fields
  # Build the graph based on the latest logs so the data is always available.
  # This also lets us distinguish 32 from 64 bit.
  foreach my $Bitness ("32", "64")
  {
    my ($Sum, $Count, $Max) = (0, 0, 0);
    foreach my $VM (@SortedVMs)
    {
      next if ($VM->Type ne "win32" and $VM->Type ne "win64");
      my $Filename = "$DataDir/latest/". $VM->Name ."_$Bitness.log";
      my $Size = -s $Filename;
      if (defined $Size)
      {
        $Count++;
        $Sum += $Size;
        $Max = $Size if ($Max < $Size);
      }
    }

    if ($Count)
    {
      print "avgreportsize$Bitness.label Average $Bitness bit size\n";
      print "avgreportsize$Bitness.type GAUGE\n";
      print "avgreportsize$Bitness.draw LINE1\n";
      print "avgreportsize$Bitness.min 0\n";
      $Value = $Sum / $Count;
      push @Data, "avgreportsize$Bitness.value $Value\n";

      print "maxreportsize$Bitness.label Maximum $Bitness bit size\n";
      print "maxreportsize$Bitness.type GAUGE\n";
      print "maxreportsize$Bitness.draw LINE1\n";
      print "maxreportsize$Bitness.min 0\n";
      push @Data, "maxreportsize$Bitness.value $Max\n";
    }
  }

  print "\n";
  push @Data, "\n";


  # Then print the corresponding data
  print "===== data =====\n";
  map { print $_ } @Data;

}

my $Request = shift;

my $CGIObj = CGI->new($Request);
my $APIKey = $CGIObj->param("APIKey");

if (!defined $APIKey or !defined $MuninAPIKey or $APIKey ne $MuninAPIKey)
{
  $Request->headers_out->set("Location", "/");
  $Request->status(Apache2::Const::REDIRECT);
  exit;
}

GetOutput($Request);

exit;
