# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Job details page
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

package JobDetailsPage;

use ObjectModel::CGI::CollectionPage;
our @ISA = qw(ObjectModel::CGI::CollectionPage);

use URI::Escape;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::LogUtils;
use WineTestBot::StepsTasks;
use WineTestBot::Engine::Notify;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  my $JobId = $self->GetParam("Key");
  if (! defined($JobId))
  {
    $JobId = $self->GetParam("JobId");
  }
  $self->{Job} = CreateJobs()->GetItem($JobId);
  if (!defined $self->{Job})
  {
    $self->Redirect("/index.pl"); # does not return
  }
  $self->{JobId} = $JobId;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateStepsTasks(undef, $self->{Job}));
}

sub GetPageTitle($)
{
  my ($self) = @_;

  my $PageTitle = $self->{Job}->Remarks;
  $PageTitle =~ s/^[[]wine-patches[]] //;
  $PageTitle = "Job " . $self->{JobId} if ($PageTitle eq "");
  $PageTitle .= " - ${ProjectName} Test Bot";
  return $PageTitle;
}

sub GetTitle($)
{
  my ($self) = @_;

  return "Job " . $self->{JobId} . " - " . $self->{Job}->Remarks;
}

sub DisplayProperty($$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();

  return $PropertyName eq "StepNo" || $PropertyName eq "TaskNo" ||
         $PropertyName eq "Status" || $PropertyName eq "VM" ||
         $PropertyName eq "Timeout" || $PropertyName eq "FileName" ||
         $PropertyName eq "CmdLineArg" || $PropertyName eq "Started" ||
         $PropertyName eq "Ended" || $PropertyName eq "TestFailures";
}

sub GetItemActions($$)
{
  #my ($self, $CollectionBlock) = @_;
  return [];
}

sub CanCancel($)
{
  my ($self) = @_;

  my $Status = $self->{Job}->Status;
  if ($Status ne "queued" && $Status ne "running")
  {
    return "Job already $Status"; 
  }

  my $Session = $self->GetCurrentSession();
  if (! defined($Session))
  {
    return "You are not authorized to cancel this job";
  }
  my $CurrentUser = $Session->User;
  if (! $CurrentUser->HasRole("admin") &&
      $self->{Job}->User->GetKey() ne $CurrentUser->GetKey())
  {
    return "You are not authorized to cancel this job";
  }

  return undef;
}

sub CanRestart($)
{
  my ($self) = @_;

  my $Status = $self->{Job}->Status;
  if ($Status ne "boterror" && $Status ne "canceled")
  {
    return "Not a failed / canceled Job";
  }

  my $Session = $self->GetCurrentSession();
  if (! defined($Session))
  {
    return "You are not authorized to restart this job";
  }
  my $CurrentUser = $Session->User;
  if (! $CurrentUser->HasRole("admin") &&
      $self->{Job}->User->GetKey() ne $CurrentUser->GetKey()) # FIXME: Admin only?
  {
    return "You are not authorized to restart this job";
  }

  return undef;
}

sub GetActions($$)
{
  my ($self, $CollectionBlock) = @_;

  # These are mutually exclusive
  return ["Cancel job"] if (!defined $self->CanCancel());
  return ["Restart job"] if (!defined $self->CanRestart());
  return [];
}

sub OnCancel($)
{
  my ($self) = @_;

  my $ErrMessage = $self->CanCancel();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $ErrMessage = JobCancel($self->{JobId});
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $self->Redirect("/JobDetails.pl?Key=" . $self->{JobId}); # does not return
  exit;
}

sub OnRestart($)
{
  my ($self) = @_;

  my $ErrMessage = $self->CanRestart();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $ErrMessage = JobRestart($self->{JobId});
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $self->Redirect("/JobDetails.pl?Key=" . $self->{JobId}); # does not return
  exit;
}

sub OnAction($$$)
{
  my ($self, $CollectionBlock, $Action) = @_;

  if ($Action eq "Cancel job")
  {
    return $self->OnCancel();
  }
  elsif ($Action eq "Restart job")
  {
    return $self->OnRestart();
  }

  return $self->SUPER::OnAction($CollectionBlock, $Action);
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  my @SortedKeys = sort { $a <=> $b } @$Keys;
  return \@SortedKeys;
}

sub GeneratePage($)
{
  my ($self) = @_;

  if ($self->{Job}->Status =~ /^(queued|running)$/)
  {
    $self->{Request}->headers_out->add("Refresh", "30");
  }

  $self->SUPER::GeneratePage();
}

=pod
=over 12

=item C<GetHtmlLine()>

Determines if the log line should be shown, how, and escapes it so it is valid
HTML.

When not showing the full log, returns undef except for error messages which
are the only lines tha should be shown.
When showing the full log error messages and other lines of interest are
highlighted to make the log more readable.

=back
=cut

sub GetHtmlLine($$$)
{
  my ($self, $FullLog, $Line) = @_;

  my $Category = GetLogLineCategory($Line);
  return undef if ($Category !~ /error/ and !$FullLog);

  my $Html = $self->escapeHTML($Line);
  if (!$FullLog and $Html =~ m/^[^:]+:([^:]*)(?::[0-9a-f]+)? done \(258\)/)
  {
    my $Unit = $1;
    return $Unit ne "" ? "$Unit: Timeout" : "Timeout";
  }
  if ($FullLog and $Category ne "none")
  {
    # Highlight all line categories in the full log
    $Html =~ s~^(.*\S)\s*\r?$~<span class='log-$Category'>$1</span>~;
  }
  return $Html;
}

sub InitMoreInfo($)
{
  my ($self) = @_;

  my $More = $self->{More} = {};
  my $Keys = $self->SortKeys(undef, $self->{Collection}->GetKeys());
  foreach my $Key (@$Keys)
  {
    my $StepTask = $self->{Collection}->GetItem($Key);
    $More->{$Key}->{Screenshot} = $self->GetParam("s$Key");

    my $Value = $self->GetParam("f$Key");
    my $TaskDir = $StepTask->GetTaskDir();
    foreach my $Log (@{GetLogFileNames($TaskDir, 1)})
    {
      if ($Log =~ s/^err/log/)
      {
        # We don't want separate entries for log* and err* but we also want a
        # log* entry even if only err* exists.
        next if (($More->{$Key}->{Logs}->[-1] || "") eq $Log);
      }
      push @{$More->{$Key}->{Logs}}, $Log;
      $More->{$Key}->{Full} = $Log if (uri_escape($Log) eq $Value);
    }
    $More->{$Key}->{Full} ||= "";
  }
}

sub GenerateMoreInfoLink($$$;$)
{
  my ($self, $LinkKey, $Label, $Set, $Value) = @_;

  my $Url = $ENV{"SCRIPT_NAME"} ."?Key=". uri_escape($self->{JobId});

  my $Action = "Show". ($Set eq "Full" and $Label !~ /old/ ? " full" : "");
  foreach my $Key (sort keys %{$self->{More}})
  {
    my $MoreInfo = $self->{More}->{$Key};
    if ($Key eq $LinkKey and $Set eq "Screenshot")
    {
      if (!$MoreInfo->{Screenshot})
      {
        $Url .= "&s$Key=1";
      }
      else
      {
        $Action = "Hide";
      }
    }
    else
    {
      $Url .= "&s$Key=1" if ($MoreInfo->{Screenshot});
    }

    if ($Key eq $LinkKey and $Set eq "Full")
    {
      if ($MoreInfo->{Full} ne $Value)
      {
        $Url .= "&f$Key=". uri_escape($Value);
      }
      else
      {
        $Action = "Hide";
      }
    }
    else
    {
      $Url .= "&f$Key=". uri_escape($MoreInfo->{Full}) if ($MoreInfo->{Full});
    }
  }
  $Url .= "#k" . uri_escape($LinkKey);

  my $Html = "<a href='". $self->CGI->escapeHTML($Url) ."'>$Action $Label</a>";
  if ($Action eq "Hide")
  {
    $Html = "<span class='TaskMoreInfoSelected'>$Html</span>";
  }
  print "<div class='TaskMoreInfoLink'>$Html</div>\n";
}

sub GenerateBody($)
{
  my ($self) = @_;

  $self->SUPER::GenerateBody();

  $self->InitMoreInfo();

  print "<div class='Content'>\n";
  my $Keys = $self->SortKeys(undef, $self->{Collection}->GetKeys());
  foreach my $Key (@$Keys)
  {
    my $StepTask = $self->{Collection}->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();
    my $VM = $StepTask->VM;
    print "<h2><a name='k", $self->escapeHTML($Key), "'></a>" ,
          $self->escapeHTML($StepTask->GetTitle()), "</h2>\n";

    print "<details><summary>",
          $self->CGI->escapeHTML($VM->Description || $VM->Name), "</summary>",
          $self->CGI->escapeHTML($VM->Details || "No details!"),
          "</details>\n";

    my $MoreInfo = $self->{More}->{$Key};
    print "<div class='TaskMoreInfoLinks'>\n";
    if (-r "$TaskDir/screenshot.png")
    {
      if ($MoreInfo->{Screenshot})
      {
        my $URI = "/Screenshot.pl?JobKey=" . uri_escape($self->{JobId}) .
                  "&StepKey=" . uri_escape($StepTask->StepNo) .
                  "&TaskKey=" . uri_escape($StepTask->TaskNo);
        print "<div class='Screenshot'><img src='" .
              $self->CGI->escapeHTML($URI) . "' alt='Screenshot' /></div>\n";
      }
      $self->GenerateMoreInfoLink($Key, "final screenshot", "Screenshot");
    }

    foreach my $Log (@{$MoreInfo->{Logs}})
    {
      $self->GenerateMoreInfoLink($Key, GetLogLabel($Log), "Full", $Log);
    }
    print "</div>\n";

    my $LogName = $MoreInfo->{Full} || $MoreInfo->{Logs}->[0] || "log";
    my $ErrName = $LogName eq "log.old" ? "err.old" : "err";

    my ($EmptyDiag, $LogFirst) = (undef, 1);
    if (open(my $LogFile, "<", "$TaskDir/$LogName"))
    {
      my $HasLogEntries;
      my ($CurrentDll, $PrintedDll) = ("", "");
      foreach my $Line (<$LogFile>)
      {
        $HasLogEntries = 1;
        chomp $Line;
        $CurrentDll = $1 if ($Line =~ m/^([_.a-z0-9-]+):[_a-z0-9]* start /);
        my $Html = $self->GetHtmlLine($MoreInfo->{Full}, $Line);
        next if (!defined $Html);

        if ($PrintedDll ne $CurrentDll && !$MoreInfo->{Full})
        {
          print "</code></pre>" if (!$LogFirst);
          print "<div class='LogDllName'>$CurrentDll:</div><pre><code>";
          $PrintedDll = $CurrentDll;
          $LogFirst = 0;
        }
        elsif ($LogFirst)
        {
          print "<pre><code>";
          $LogFirst = 0;
        }
        print "$Html\n";
      }
      close($LogFile);

      if (!$LogFirst)
      {
        print "</code></pre>\n";
      }
      elsif ($HasLogEntries)
      {
        # Here we know we did not show the full log since it was not empty,
        # and yet we did not show anything to the user. But don't claim there
        # is no failure if the error log is not empty.
        if (-z "$TaskDir/$ErrName")
        {
          print "No ". ($StepTask->Type eq "single" ||
                        $StepTask->Type eq "suite" ? "test" : "build") .
                " failures found";
          $LogFirst = 0;
        }
      }
      elsif ($StepTask->Status eq "canceled")
      {
        $EmptyDiag = "<p>No log, task was canceled</p>\n";
      }
      elsif ($StepTask->Status eq "skipped")
      {
        $EmptyDiag = "<p>No log, task skipped</p>\n";
      }
      else
      {
        print "Empty log";
        $LogFirst = 0;
      }
    }
    else
    {
      print "No log". ($StepTask->Status =~ /^(?:queued|running)$/ ? " yet" : "");
      $LogFirst = 0;
    }

    if (open(my $ErrFile, "<", "$TaskDir/$ErrName"))
    {
      my $ErrFirst = 1;
      foreach my $Line (<$ErrFile>)
      {
        chomp $Line;
        if ($ErrFirst)
        {
          if (!$LogFirst)
          {
            print "<div class='HrTitle'>".
                  ($ErrName eq "err" ? "Other errors" : "Old errors") .
                  "<div class='HrLine'></div></div>\n";
          }
          print "<pre><code>";
          $ErrFirst = 0;
        }
        print $self->GetHtmlLine(1, $Line), "\n";
      }
      close($ErrFile);

      if (!$ErrFirst)
      {
        print "</code></pre>\n";
      }
      elsif (defined $EmptyDiag)
      {
        print $EmptyDiag;
      }
    }
  }
  print "</div>\n";
}

sub GenerateDataCell($$$$$)
{
  my ($self, $CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  if ($PropertyName eq "VM")
  {
    print "<td><a href='#k", $self->escapeHTML($StepTask->GetKey()), "'>";
    print $self->escapeHTML($self->GetDisplayValue($CollectionBlock, $StepTask,
                                                   $PropertyDescriptor));
    print "</a></td>\n";
  }
  elsif ($PropertyName eq "FileName")
  {
    my $FileName = $StepTask->GetFullFileName();
    if ($FileName and -r $FileName)
    {
      my $URI = "/GetFile.pl?JobKey=" . uri_escape($self->{JobId}) .
                  "&StepKey=" . uri_escape($StepTask->StepNo);
      print "<td><a href='" . $self->escapeHTML($URI) . "'>";
      print $self->escapeHTML($self->GetDisplayValue($CollectionBlock, $StepTask,
                                                     $PropertyDescriptor));
      print "</a></td>\n";
    }
    else
    {
      $self->SUPER::GenerateDataCell($CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage);
    }
  }
  else
  {
    $self->SUPER::GenerateDataCell($CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage);
  }
}


package main;

my $Request = shift;

my $JobDetailsPage = JobDetailsPage->new($Request, "");
$JobDetailsPage->GeneratePage();
