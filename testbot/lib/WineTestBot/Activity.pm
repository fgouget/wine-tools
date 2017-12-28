# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package WineTestBot::Activity;

=head1 NAME

WineTestBot::Activity -  reconstruct the TestBot's activity from its history records.

=cut

use Scalar::Util qw(weaken);
use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::RecordGroups;
use WineTestBot::Records;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(&GetActivity &GetStatistics);


=pod
=over 12

=item C<GetActivity()>

Loads the records for the specified VMs and processes them to build a structure
describing the TestBot activity. The structure is as follows:

  { <GroupNo1> => {
      start    => <StartTimestamp>,
      end      => <EndTimestamp>,
      runnable => <RunnableTasksCount>,
      queued   => <QueuedTasksCount>,
      engine   => <StartOrStop>,
      statusvms => {
        <VMName1> => {
          vm     => <VMObject>,
          status => <VMStatus>,
          value  => <RecordValue>,
          task   => <TaskObjectIfAppopriate>,
          start  => <StartTimestamp>,
          end    => <EndTimestamp>,
          rows   => <NbRows>,
        },
        <VMName2> => {
          ...
        },
      },
      resultvms => {
        <VMName1> => {
          vm       => <VMObject>,
          result   => <VMResult>,
          tries    => <Tries>,
          maxtries => <MaxTries>,
          details  => <ResultDetails>,
        },
        <VMName2> => {
          ...
        },
      },
    },
    <GroupNo2> => {
      ...
    },
    ...
  }

=back
=cut

sub GetActivity($)
{
  my ($VMs) = @_;
  my ($Activity, $Counters) = ({}, {});

  ### First load all the RecordGroups
  my $RecordGroups = CreateRecordGroups();
  $Counters->{recordgroups} = $RecordGroups->GetItemsCount();
  foreach my $RecordGroup (@{$RecordGroups->GetItems()})
  {
    $Activity->{$RecordGroup->Id} = { start => $RecordGroup->Timestamp };
  }

  ### And then load all the Records in one go
  # Loading the whole table at once is more efficient than loading it piecemeal
  # one RecordGroup at a time.

  my $Jobs = CreateJobs();
  my $Records = CreateRecords();
  $Counters->{records} = $Records->GetItemsCount();
  foreach my $Record (@{$Records->GetItems()})
  {
    my $Group = $Activity->{$Record->RecordGroupId};
    if ($Record->Type eq "tasks" and $Record->Name eq "counters")
    {
      ($Group->{runnable}, $Group->{queued}) = split / /, $Record->Value;
    }
    elsif ($Record->Type eq "engine" and $Record->Name =~ /^(?:start|stop)$/)
    {
      $Group->{engine} = $Record->Name;
      foreach my $VM (@{$VMs->GetItems()})
      {
        my $StatusVMs = ( $Group->{statusvms} ||= {} );
        my $VMStatus = ( $StatusVMs->{$VM->Name} ||= {} );
        $VMStatus->{vmstatus} = $VMStatus;
        weaken($VMStatus->{vmstatus}); # avoid memory cycles
        $VMStatus->{start} = $Group->{start};
        $VMStatus->{status} = "engine";
        $VMStatus->{rows} = 1;
      }
    }
    elsif ($Record->Type eq "vmstatus")
    {
      # Ignore retired / deleted VMs
      my ($RecordName, $RecordHost) = split / /, $Record->Name;
      next if (!$VMs->ItemExists($RecordName));

      my $StatusVMs = ( $Group->{statusvms} ||= {} );
      my $VMStatus = ( $StatusVMs->{$RecordName} ||= {} );

      $VMStatus->{host} = $RecordHost;
      $VMStatus->{vmstatus} = $VMStatus;
      weaken($VMStatus->{vmstatus}); # avoid memory cycles
      $VMStatus->{start} = $Group->{start};
      my ($Status, @Extra) = split / /, $Record->Value;
      $VMStatus->{status} = $Status;
      $VMStatus->{rows} = 1;

      $VMStatus->{result} = "";
      if ($Status eq "running")
      {
        $VMStatus->{job} = $Jobs->GetItem($Extra[0]);
        $VMStatus->{step} = $VMStatus->{job}->Steps->GetItem($Extra[1]) if ($VMStatus->{job});
        $VMStatus->{task} = $VMStatus->{step}->Tasks->GetItem($Extra[2]) if ($VMStatus->{step});
        if ($VMStatus->{task})
        {
          if ($VMStatus->{task}->Status =~ /^(?:badpatch|badbuild|boterror)$/)
          {
            $VMStatus->{result} = $VMStatus->{task}->Status;
          }
          elsif ($VMStatus->{task}->Status eq "completed" and
                 $VMStatus->{task}->TestFailures)
          {
            $VMStatus->{result} = "failed";
          }
        }
      }
      elsif (@Extra)
      {
        # @Extra contains details about the current status, such as what
        # type of process a dirty VM is running, or how it came to be dirty
        # in the first place.
        $VMStatus->{details} = join(" ", @Extra);
      }
    }
    elsif ($Record->Type eq "vmresult")
    {
      my ($RecordName, $RecordHost) = split / /, $Record->Name;
      next if (!$VMs->ItemExists($RecordName));

      my $ResultVMs = ( $Group->{resultvms} ||= {} );
      my $VMResult = ( $ResultVMs->{$RecordName} ||= {} );

      $VMResult->{host} = $RecordHost;
      my ($Result, @Extras) = split / /, $Record->Value;
      $VMResult->{result} = $Result;
      if (@Extras >= 2 and $Extras[0] =~ /^\d+$/ and $Extras[1] =~ /^\d+$/)
      {
        $VMResult->{tries} = shift @Extras;
        $VMResult->{maxtries} = shift @Extras;
      }
      $VMResult->{details} = join(" ", @Extras);
    }
  }

  ### Fill the holes in the table, compute end times, etc.

  my ($LastGroup, %LastStatusVMs);
  foreach my $RecordGroup (sort CompareRecordGroups @{$RecordGroups->GetItems()})
  {
    my $Group = $Activity->{$RecordGroup->Id};
    my $StatusVMs = $Group->{statusvms};
    my $ResultVMs = $Group->{resultvms};
    next if (!$StatusVMs and !$ResultVMs);
    if ($LastGroup)
    {
      $LastGroup->{end} = $Group->{start};
      foreach my $Counter ('runnable', 'queued')
      {
        if (!exists $Group->{$Counter} and exists $LastGroup->{$Counter})
        {
          $Group->{$Counter} = $LastGroup->{$Counter};
        }
      }
    }
    $LastGroup = $Group;

    foreach my $VM (@{$VMs->GetItems()})
    {
      my $LastVMStatus = $LastStatusVMs{$VM->Name} ? $LastStatusVMs{$VM->Name}->{$VM->Name} : undef;

      my $VMResult = $ResultVMs->{$VM->Name};
      if ($VMResult and $LastVMStatus and $LastVMStatus->{status} ne "engine")
      {
        # Transfer the result to the relevant status object
        $LastVMStatus->{result} = $VMResult->{result};
        $LastVMStatus->{details} = $VMResult->{details};
        $LastVMStatus->{tries} = $VMResult->{tries};
        $LastVMStatus->{maxtries} = $VMResult->{maxtries};
      }
      next if (!$StatusVMs);

      my $VMStatus = $StatusVMs->{$VM->Name};
      if ($VMStatus)
      {
        $LastVMStatus->{end} = $VMStatus->{start} if ($LastVMStatus);
      }
      elsif ($LastVMStatus and $LastVMStatus->{status} ne "engine")
      {
        $VMStatus = $StatusVMs->{$VM->Name} = $LastVMStatus;
        $LastStatusVMs{$VM->Name}->{$VM->Name} = {merged => 1, vmstatus => $VMStatus};
        $VMStatus->{rows}++;
      }
      else
      {
        $VMStatus = $StatusVMs->{$VM->Name} = {
          start => $Group->{start},
          status => "unknown",
          rows => 1};
        $VMStatus->{vmstatus} = $VMStatus;
        weaken($VMStatus->{vmstatus}); # avoid memory cycles
      }
      if ($LastVMStatus and $LastVMStatus->{status} ne $VMStatus->{status} and
          # Ignore acts of administrator
          $VMStatus->{status} !~ /^(?:maintenance|engine)$/ and
          # And flag forbidden transitions
          (($LastVMStatus->{status} eq "reverting" and $VMStatus->{status} ne "sleeping") or
           ($LastVMStatus->{status} eq "sleeping" and $VMStatus->{status} !~ /^(?:idle|running)$/) or
           ($LastVMStatus->{status} eq "idle" and $VMStatus->{status} ne "running")))
      {
        $LastVMStatus->{mispredict} = 1;
      }
      $LastStatusVMs{$VM->Name} = $StatusVMs;
    }
  }
  $LastGroup->{end} = time() if ($LastGroup);

  foreach my $VM (@{$VMs->GetItems()})
  {
    my $LastVMStatus = $LastStatusVMs{$VM->Name}->{$VM->Name};
    next if (!$LastVMStatus);
    $LastVMStatus->{end} = time();
    if ($LastVMStatus->{status} eq "unknown")
    {
      $LastVMStatus->{status} = $VM->Status;
    }
  }

  return ($Activity, $Counters);
}

sub _AddFullStat($$$;$)
{
  my ($Stats, $StatKey, $Value, $Source) = @_;

  $Stats->{"$StatKey.count"}++;
  $Stats->{$StatKey} += $Value;
  my $MaxKey = "$StatKey.max";
  if (!exists $Stats->{$MaxKey} or $Stats->{$MaxKey} < $Value)
  {
    $Stats->{$MaxKey} = $Value;
    $Stats->{"$MaxKey.source"} = $Source if ($Source);
  }
}

sub GetStatistics($)
{
  my ($VMs) = @_;

  my ($GlobalStats, $HostsStats, $VMsStats) = ({}, {}, {});

  my @JobTimes;
  my $Jobs = CreateJobs();
  foreach my $Job (@{$Jobs->GetItems()})
  {
    $GlobalStats->{"jobs.count"}++;

    my $IsSpecialJob;
    my $Steps = $Job->Steps;
    foreach my $Step (@{$Steps->GetItems()})
    {
      my $StepType = $Step->Type;
      $IsSpecialJob = 1 if ($StepType =~ /^(?:reconfig|suite)$/);

      my $Tasks = $Step->Tasks;
      foreach my $Task (@{$Tasks->GetItems()})
      {
        $GlobalStats->{"tasks.count"}++;
        if ($Task->Started and $Task->Ended and
            $Task->Status !~ /^(?:queued|running|canceled)$/)
        {
          my $Time = $Task->Ended - $Task->Started;
          _AddFullStat($GlobalStats, "$StepType.time", $Time, $Task);
        }
        if ($IsSpecialJob)
        {
          my $ReportFileName = $Task->GetDir() . "/log";
          if (-f $ReportFileName)
          {
            my $ReportSize = -s $ReportFileName;
            _AddFullStat($GlobalStats, "$StepType.size", $ReportSize, $Task);
            if ($VMs->ItemExists($Task->VM->GetKey()))
            {
              my $VMStats = ($VMsStats->{items}->{$Task->VM->Name} ||= {});
              _AddFullStat($VMStats, "report.size", $ReportSize, $Task);
            }
          }
        }
      }
    }

    if (!$IsSpecialJob and$Job->Ended and
        $Job->Status !~ /^(?:queued|running|canceled)$/)
    {
      my $Time = $Job->Ended - $Job->Submitted;
      _AddFullStat($GlobalStats, "jobs.time", $Time, $Job);
      push @JobTimes, $Time;

      if (!exists $GlobalStats->{start} or $GlobalStats->{start} > $Job->Submitted)
      {
        $GlobalStats->{start} = $Job->Submitted;
      }
      if (!exists $GlobalStats->{end} or $GlobalStats->{end} < $Job->Ended)
      {
        $GlobalStats->{end} = $Job->Ended;
      }
    }
  }

  my $JobCount = $GlobalStats->{"jobs.time.count"};
  if ($JobCount)
  {
    @JobTimes = sort { $a <=> $b } @JobTimes;
    $GlobalStats->{"jobs.time.p10"} = $JobTimes[int($JobCount * 0.1)];
    $GlobalStats->{"jobs.time.p50"} = $JobTimes[int($JobCount * 0.5)];
    $GlobalStats->{"jobs.time.p90"} = $JobTimes[int($JobCount * 0.9)];
    @JobTimes = (); # free early
  }

  my ($Activity, $Counters) = GetActivity($VMs);
  $GlobalStats->{"recordgroups.count"} = $Counters->{recordgroups};
  $GlobalStats->{"records.count"} = $Counters->{records};
  foreach my $Group (values %$Activity)
  {
    if (!$VMsStats->{start} or $VMsStats->{start} > $Group->{start})
    {
      $VMsStats->{start} = $Group->{start};
    }
    if (!$VMsStats->{end} or $VMsStats->{end} < $Group->{end})
    {
      $VMsStats->{end} = $Group->{end};
    }
    next if (!$Group->{statusvms});

    my ($IsGroupBusy, %IsHostBusy);
    foreach my $VM (@{$VMs->GetItems()})
    {
      my $VMStatus = $Group->{statusvms}->{$VM->Name};
      my $Host = $VMStatus->{vmstatus}->{host} || $VM->GetHost();
      my $HostStats = ($HostsStats->{items}->{$Host} ||= {});

      if (!$VMStatus->{merged})
      {
        my $VMStats = ($VMsStats->{items}->{$VM->Name} ||= {});
        my $Status = $VMStatus->{status};

        my $Time = $VMStatus->{end} - $VMStatus->{start};
        _AddFullStat($VMStats, "$Status.time", $Time);
        _AddFullStat($HostStats, "$Status.time", $Time);
        if ($Status =~ /^(?:reverting|sleeping|running|dirty)$/)
        {
          $VMStats->{"busy.elapsed"} += $Time;
        }

        if ($VMStatus->{result} =~ /^(?:boterror|error|timeout)$/)
        {
          $VMStats->{"$VMStatus->{result}.count"}++;
          $HostStats->{"$VMStatus->{result}.count"}++;
          $GlobalStats->{"$VMStatus->{result}.count"}++;
        }
        elsif ($VMStatus->{task} and
               ($VMStatus->{result} eq "completed" or
                $VMStatus->{result} eq "failed"))
        {
          my $StepType = $VMStatus->{step}->Type;
          _AddFullStat($VMStats, "$StepType.time", $Time, $VMStatus->{task});
          _AddFullStat($HostStats, "$StepType.time", $Time, $VMStatus->{task});
        }
      }

      $VMStatus = $VMStatus->{vmstatus};
      if (!$IsHostBusy{$Host} and
          $VMStatus->{status} =~ /^(?:reverting|sleeping|running|dirty)$/)
      {
        # Note that we cannot simply sum the VMs busy wall clock times to get
        # the host busy wall clock time because this would count periods where
        # more than one VM is busy multiple times.
        $HostStats->{"busy.elapsed"} += $Group->{end} - $Group->{start};
        $IsHostBusy{$Host} = 1;
        $IsGroupBusy = 1;
      }
    }
    if ($IsGroupBusy)
    {
      $GlobalStats->{"busy.elapsed"} += $Group->{end} - $Group->{start};
    }
  }
  $GlobalStats->{elapsed} = $GlobalStats->{end} - $GlobalStats->{start};
  $HostsStats->{elapsed} =
      $VMsStats->{elapsed} = $VMsStats->{end} - $VMsStats->{start};

  return { global => $GlobalStats, hosts => $HostsStats, vms => $VMsStats };
}

1;
