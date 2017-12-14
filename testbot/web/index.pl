# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot status page
#
# Copyright 2009 Ge van Geldorp
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

package JobStatusBlock;

use URI::Escape;
use ObjectModel::CGI::CollectionBlock;
use WineTestBot::Branches;

use vars qw(@ISA);

@ISA = qw(ObjectModel::CGI::CollectionBlock);

sub SortKeys($$)
{
  my ($self, $Keys) = @_;

  my @SortedKeys = sort { $b <=> $a } @$Keys;
  return \@SortedKeys;
}

sub GetItemActions($)
{
  #my ($self) = @_;
  return [];
}

sub GetActions($)
{
  #my ($self) = @_;
  return [];
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  if ($PropertyName eq "Archived" ||
      $PropertyName eq "Patch" ||
      ($PropertyName eq "Branch" &&
       ! CreateBranches()->MultipleBranchesPresent))
  {
    return !1;
  }

  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub GetDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetName() eq "User" &&
      defined($Item->Patch) &&
      $Item->User->GetKey() eq WineTestBot::Users->GetBatchUser()->GetKey() &&
      defined($Item->Patch->FromName))
  {
    return $Item->Patch->FromName;
  }

  return $self->SUPER::GetDisplayValue($Item, $PropertyDescriptor);
}

sub GenerateDataCell($$$$)
{
  my ($self, $Item, $PropertyDescriptor, $DetailsPage) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  if ($PropertyName eq "Status")
  {
    my $EscapedKey = uri_escape($Item->GetKey());
    print "<td id='job$EscapedKey'><a href='/JobDetails.pl?Key=$EscapedKey'>";

    my %HTMLChunks = ("queued" => "<span class='queued'>queued</span>",
                      "running" => "<span class='running'>running</span>",
                      "completed" => "<span class='success'>completed</span>",
                      "badpatch" => "<span class='badpatch'>bad patch</span>",
                      "badbuild" => "<span class='badbuild'>build error</span>",
                      "boterror" => "<span class='boterror'>TestBot error</span>",
                      "canceled" => "<span class='canceled'>canceled</span>",
        );
    my $Status = $Item->Status;
    my $HTMLStatus = $HTMLChunks{$Status} || $Status;
    if ($Status eq "completed" || $Status eq "boterror" || $Status eq "canceled")
    {
      my $Failures = 0;
      my $HasTestResult;
      foreach my $Step (@{$Item->Steps->GetItems()})
      {
        foreach my $Task (@{$Step->Tasks->GetItems()})
        {
          my $TaskFailures = $Task->TestFailures;
          if ($TaskFailures ne "")
          {
            $HasTestResult = 1;
            $Failures += $TaskFailures;
          }
        }
      }
      if (!$HasTestResult)
      {
        print $HTMLStatus;
      }
      else
      {
        $HTMLStatus = $Item->Status eq "completed" ? "" : "$HTMLStatus - ";
        my $class = $Failures ? "testfail" : "success";
        my $s = $Failures == 1 ? "" : "s";
        print "$HTMLStatus<span class='$class'>$Failures test failure$s</span>";
      }
    }
    else
    {
      print $HTMLStatus;
    }
    print "</a></td>\n";
  }
  else
  {
    $self->SUPER::GenerateDataCell($Item, $PropertyDescriptor, $DetailsPage);
  }
}

package VMStatusBlock;

use ObjectModel::CGI::CollectionBlock;

use vars qw(@ISA);

@ISA = qw(ObjectModel::CGI::CollectionBlock);

sub SortKeys($$)
{
  my ($self, $Keys) = @_;

  return $self->{Collection}->SortKeysBySortOrder($Keys);
}

sub GetItemActions($)
{
  #my ($self) = @_;
  return [];
}

sub GetActions($)
{
  #my ($self) = @_;
  return [];
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return $PropertyName eq "Name" || $PropertyName eq "Type" ||
         $PropertyName eq "Role" || $PropertyName eq "Status" ||
         $PropertyName eq "Description";
}

sub GetDetailsPage($)
{
  #my ($self) = @_;
  return undef;
}

package StatusPage;

use ObjectModel::CGI::Page;
use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::VMs;

@StatusPage::ISA = qw(ObjectModel::CGI::Page);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->{start} = Time();
  $self->SUPER::_initialize($Request, $RequiredRole);
}

sub OutputDot($$)
{
  my ($self, $DotColor) = @_;

  print "<img src='/images/${DotColor}dot.jpg' alt='${DotColor} dot' " .
        "width='20' height='20' />";
}

sub GeneratePage($)
{
  my ($self) = @_;

  $self->{Request}->headers_out->add("Refresh", "60");

  $self->SUPER::GeneratePage();
}

sub GenerateBody($)
{
  my ($self) = @_;

  print "<h1>${ProjectName} Test Bot status</h1>\n";
  print "<div class='Content'>\n";

  print "<h2>General</h2>\n";
  print "<div class='GeneralStatus'>\n";
  print "<div class='GeneralStatusItem'>";
  if (PingEngine())
  {
    $self->OutputDot("green");
    print "<div class='GeneralStatusItemText'><a href='#jobs'>Engine is alive and processing jobs</a></div>";
  }
  else
  {
    $self->OutputDot("red");
    print "<div class='GeneralStatusItemText'><a href='#jobs'>Engine appears to be dead and is not processing jobs</a></div>";
  }
  print "</div>\n";
  
  my $OfflineVMs = CreateVMs();
  $OfflineVMs->FilterEnabledRole();
  $OfflineVMs->AddFilter("Status", ["offline"]);
  my $MaintenanceVMs = CreateVMs();
  $MaintenanceVMs->FilterEnabledRole();
  $MaintenanceVMs->AddFilter("Status", ["maintenance"]);
  if ($OfflineVMs->IsEmpty() and $MaintenanceVMs->IsEmpty())
  {
    print "<div class='GeneralStatusItem'>";
    $self->OutputDot("green");
    print "<div class='GeneralStatusItemText'><a href='#vms'>All VMs are online</a></div>";
    print "</div>\n";
  }
  else
  {
    if (!$OfflineVMs->IsEmpty())
    {
      print "<div class='GeneralStatusItem'>";
      $self->OutputDot("red");
      print "<div class='GeneralStatusItemText'><a href='#vms'>One or more VMs are offline</a></div>";
      print "</div>\n";
    }
    if (!$MaintenanceVMs->IsEmpty())
    {
      print "<div class='GeneralStatusItem'>";
      $self->OutputDot("red");
      print "<div class='GeneralStatusItemText'><a href='#vms'>One or more VMs are undergoing maintenance</a></div>";
      print "</div>\n";
    }
  }
  print "</div>\n";

  print "<h2><a name='jobs'></a>Jobs</h2>\n";
  my $Jobs = CreateJobs();
  $Jobs->FilterNotArchived();
  my $JobsCollectionBlock = new JobStatusBlock($Jobs, $self);
  $JobsCollectionBlock->GenerateList();

  if ($JobArchiveDays != 0)
  {
    my $PropertyDescriptor = $Jobs->GetPropertyDescriptorByName('Id');
    my $MaxIdLength = $PropertyDescriptor->GetMaxLength();
    print <<EOF
<br>
<form action='/JobDetails.pl' method='post' enctype='multipart/form-data'>
<div class='ItemProperty'>
<label>Archived job id</label><div class='ItemValue'><input type='text' name='Key' maxlength='$MaxIdLength' size='$MaxIdLength'/></div>
&nbsp;
<input type='submit' name='Action' value='Show details'/>
</div>
</form>
EOF
  }

  print "<h2><a name='vms'></a>VMs</h2>\n";
  my $VMsCollectionBlock = new VMStatusBlock(CreateVMs(), $self);
  $VMsCollectionBlock->GenerateList();
  print "</div>\n";

  print "<p class='GeneralFooterText'>Generated in ", Elapsed($self->{start}), " s</p>\n";
}

package main;

my $Request = shift;

my $StatusPage = StatusPage->new($Request, "");
$StatusPage->GeneratePage();
