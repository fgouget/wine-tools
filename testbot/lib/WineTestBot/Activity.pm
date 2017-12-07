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

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::RecordGroups;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(&GetActivity);


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

  my $Activity = {};
  my $Jobs = CreateJobs();
  my $RecordGroups = CreateRecordGroups();
  my @SortedGroupNos;
  foreach my $RecordGroup (sort CompareRecordGroups @{$RecordGroups->GetItems()})
  {
    push @SortedGroupNos, $RecordGroup->Id;
    my $Group = ( $Activity->{$RecordGroup->Id} ||= {
                  start => $RecordGroup->Timestamp}
                );
    foreach my $Record (@{$RecordGroup->Records->GetItems()})
    {
      if ($Record->Type eq "engine" and $Record->Name =~ /^(?:start|stop)$/)
      {
        $Group->{engine} = $Record->Name;
        foreach my $VM (@{$VMs->GetItems()})
        {
          my $StatusVMs = ( $Group->{statusvms} ||= {} );
          my $VMStatus = ( $StatusVMs->{$VM->Name} ||= {} );
          $VMStatus->{start} = $RecordGroup->Timestamp;
          $VMStatus->{status} = "engine";
          $VMStatus->{rows} = 1;
        }
      }
      elsif ($Record->Type eq "tasks")
      {
        $Group->{$Record->Name} = $Record->Value;
      }
      elsif ($Record->Type eq "vmstatus")
      {
        # Ignore retired / deleted VMs
        my ($RecordName, $RecordHost) = split / /, $Record->Name;
        # Use ItemExists() to not bypass the collection's filter
        next if (!$VMs->ItemExists($RecordName));
        my $VM = $VMs->GetItem($RecordName);

        my $StatusVMs = ( $Group->{statusvms} ||= {} );
        my $VMStatus = ( $StatusVMs->{$RecordName} ||= {} );

        $VMStatus->{host} = $RecordHost;
        $VMStatus->{vm} = $VM;
        $VMStatus->{vmstatus} = $VMStatus;
        $VMStatus->{start} = $RecordGroup->Timestamp;
        my ($Status, @Extra) = split / /, $Record->Value;
        $VMStatus->{status} = $Status;
        $VMStatus->{value} = $Record->Value;
        $VMStatus->{rows} = 1;

        if ($Status eq "running")
        {
          $VMStatus->{job} = $Jobs->GetItem($Extra[0]);
          $VMStatus->{step} = $VMStatus->{job}->Steps->GetItem($Extra[1]) if ($VMStatus->{job});
          $VMStatus->{task} = $VMStatus->{step}->Tasks->GetItem($Extra[2]) if ($VMStatus->{step});
        }
        elsif (@Extra)
        {
          # @Extra contains details about the current status, such as what
          # type of process a dirty VM is running, or how it came to be dirty
          # in the first place.
          $VMStatus->{details} = join(" ", @Extra);
        }
      }
    }
  }

  ### Fill the holes in the table, compute end times, etc.

  my ($LastGroup, %LastStatusVMs);
  foreach my $GroupNo (@SortedGroupNos)
  {
    my $Group = $Activity->{$GroupNo};
    my $StatusVMs = $Group->{statusvms};
    next if (!$StatusVMs);
    $LastGroup->{end} = $Group->{start} if ($LastGroup);
    $LastGroup = $Group;

    foreach my $VM (@{$VMs->GetItems()})
    {
      my $LastVMStatus = $LastStatusVMs{$VM->Name} ? $LastStatusVMs{$VM->Name}->{$VM->Name} : undef;

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
    $LastVMStatus->{end} = time() if ($LastVMStatus);
  }

  return $Activity;
}

1;
