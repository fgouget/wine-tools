# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot job submit page
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014, 2017-2018 Francois Gouget
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

package SubmitPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use CGI qw(:standard);
use Fcntl; # For O_XXX
use IO::Handle;
use POSIX qw(:fcntl_h); # For SEEK_XXX
use File::Basename;

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Branches;
use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::Jobs;
use WineTestBot::PatchUtils;
use WineTestBot::Steps;
use WineTestBot::Utils;
use WineTestBot::VMs;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->{Page} = $self->GetParam("Page") || 1;

  my @PropertyDescriptors1 = (
    CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "A", 128),
  );
  $self->{PropertyDescriptors1} = \@PropertyDescriptors1;

  my @PropertyDescriptors3 = (
    CreateBasicPropertyDescriptor("TestExecutable", "Test executable", !1, 1, "A", 50),
    CreateBasicPropertyDescriptor("CmdLineArg", "Command line arguments", !1, !1, "A", 50),
    CreateBasicPropertyDescriptor("Run64", "Run 64-bit tests in addition to 32-bit tests", !1, 1, "B", 1),
    CreateBasicPropertyDescriptor("DebugLevel", "Debug level (WINETEST_DEBUG)", !1, 1, "N", 2),
    CreateBasicPropertyDescriptor("ReportSuccessfulTests", "Report successful tests (WINETEST_REPORT_SUCCESS)", !1, 1, "B", 1),
  );
  $self->{PropertyDescriptors3} = \@PropertyDescriptors3;

  if ($self->{Page} == 2)
  {
    $self->{ShowAll} = defined($self->GetParam("ShowAll"));
  }

  $self->SUPER::_initialize($Request, $RequiredRole, undef);
}

sub GetTitle($)
{
  #my ($self) = @_;
  return "Submit a job";
}

sub GetHeaderText($)
{
  my ($self) = @_;

  if ($self->{Page} == 1)
  {
    return "Specify the patch file that you want to upload and submit " .
           "for testing.<br>\n" .
           "You can also specify a Windows .exe file, this would normally be " .
           "a Wine test executable that you cross-compiled."
  }
  elsif ($self->{Page} == 2)
  {
    my $HeaderText = "Select the VMs on which you want to run your test.";
    my $VMs = CreateVMs();
    $VMs->AddFilter("Status", ["offline", "maintenance"]);
    if (!$VMs->IsEmpty())
    {
      $HeaderText .= "<br>NOTE: Offline VMs and those undergoing maintenance will not be able to run your tests right away.";
    }
    return $HeaderText;
  }
  elsif ($self->{Page} == 4)
  {
    return "Your job was successfully queued, but the job engine that takes " .
           "care of actually running it seems to be unavailable (perhaps it " .
           "crashed). Your job will remain queued until the engine is " .
           "restarted.";
  }

  return "";
}

sub GetPropertyDescriptors($)
{
  my ($self) = @_;

  if ($self->{Page} == 1)
  {
    return $self->{PropertyDescriptors1};
  }
  elsif ($self->{Page} == 3)
  {
    my $IsPatch = ($self->GetParam("FileType") eq "patchdlls");
    $self->{PropertyDescriptors3}[0]->{IsRequired} = $IsPatch;
    return $self->{PropertyDescriptors3};
  }

  return $self->SUPER::GetPropertyDescriptors();
}

sub GenerateFields($)
{
  my ($self) = @_;

  print "<div><input type='hidden' name='Page' value='", $self->{Page},
        "'></div>\n";
  if ($self->{Page} == 1)
  {
    print "<div class='ItemProperty'><label>File</label>",
          "<div class='ItemValue'>",
          "<input type='file' name='File' size='64' maxlength='64' />",
          "&nbsp;<span class='Required'>*</span></div></div>\n";
    my $Branches = CreateBranches();
    my $SelectedBranchKey = $self->GetParam("Branch");
    if (! defined($SelectedBranchKey))
    {
      $SelectedBranchKey = $Branches->GetDefaultBranch()->GetKey();
    }
    if (! $Branches->MultipleBranchesPresent())
    {
      print "<div><input type='hidden' name='Branch' value='",
            $self->CGI->escapeHTML($SelectedBranchKey),
            "'></div>\n";
    }
    else
    {
      print "<div class='ItemProperty'><label>Branch</label>",
            "<div class='ItemValue'>",
            "<select name='Branch' size='1'>";
      my @SortedKeys = sort { $a cmp $b } @{$Branches->GetKeys()};
      foreach my $Key (@SortedKeys)
      {
        my $Branch = $Branches->GetItem($Key);
        print "<option value='", $self->CGI->escapeHTML($Key), "'";
        if ($Key eq $SelectedBranchKey)
        {
          print " selected";
        }
        print ">", $self->CGI->escapeHTML($Branch->Name), "</option>";
      }
      print "</select>",
            "&nbsp;<span class='Required'>*</span></div></div>\n";
    }

    $self->{HasRequired} = 1;
  }
  else
  {
    if (! defined($self->{FileName}))
    {
      $self->{FileName} = $self->GetParam("FileName");
    }
    if (! defined($self->{FileType}))
    {
      $self->{FileType} = $self->GetParam("FileType");
    }
    if (! defined($self->{TestExecutable}))
    {
      $self->{TestExecutable} = $self->GetParam("TestExecutable");
    }
    if (! defined($self->{CmdLineArg}))
    {
      $self->{CmdLineArg} = $self->GetParam("CmdLineArg");
    }
    print "<div><input type='hidden' name='Remarks' value='",
          $self->CGI->escapeHTML($self->GetParam("Remarks")), "'></div>\n";
    print "<div><input type='hidden' name='FileName' value='",
          $self->CGI->escapeHTML($self->{FileName}), "'></div>\n";
    print "<div><input type='hidden' name='FileType' value='",
          $self->CGI->escapeHTML($self->{FileType}), "'></div>\n";
    print "<div><input type='hidden' name='Branch' value='",
          $self->CGI->escapeHTML($self->GetParam("Branch")), "'></div>\n";
    if ($self->{Page} != 3)
    {
      if (defined($self->{TestExecutable}))
      {
        print "<div><input type='hidden' name='TestExecutable' value='",
              $self->CGI->escapeHTML($self->{TestExecutable}), "'></div>\n";
      }
      if (defined($self->{CmdLineArg}))
      {
        print "<div><input type='hidden' name='CmdLineArg' value='",
              $self->CGI->escapeHTML($self->{CmdLineArg}), "'></div>\n";
      }
    }
    if ($self->{Page} == 2)
    {
      if ($self->GetParam("Page") == 3)
      {
        my $VMs = CreateVMs();
        # VMs that are only visible with ShowAll
        $VMs->AddFilter("Role", ["winetest", "extra"]);
        foreach my $VMKey (@{$VMs->GetKeys()})
        {
          my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
          if (defined $self->GetParam($FieldName))
          {
            $self->{ShowAll} = 1;
            last;
          }
        }
      }
      if ($self->{ShowAll})
      {
        print "<div><input type='hidden' name='ShowAll' value='1'></div>\n";
      }
      print "<div class='CollectionBlock'><table>\n";
      print "<thead><tr><th class='Record'></th>\n";
      print "<th class='Record'>VM Name</th>\n";
      print "<th class='Record'>Description</th>\n";
      print "</th><tbody>\n";

      my $VMs = CreateVMs();
      if ($self->{FileType} eq "exe64")
      {
          $VMs->AddFilter("Type", ["win64"]);
      }
      else
      {
          $VMs->AddFilter("Type", ["win32", "win64"]);
      }
      if ($self->{ShowAll})
      {
        # All but the retired and deleted ones
        $VMs->AddFilter("Role", ["base", "winetest", "extra"]);
      }
      else
      {
        $VMs->AddFilter("Role", ["base"]);
      }
      my $Even = 1;
      my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
      foreach my $VMKey (@$SortedKeys)
      {
        my $VM = $VMs->GetItem($VMKey);
        my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
        print "<tr class='", ($Even ? "even" : "odd"),
            "'><td><input name='$FieldName' type='checkbox'";
        $Even = !$Even;
        my ($Checked, $Status) = (1, "");
        if ($VM->Status =~ /^(offline|maintenance)$/)
        {
          $Status = " [". $VM->Status ."]";
          $Checked = undef;
        }
        if ($Checked and
            ($self->GetParam("Page") == 1 || $self->GetParam($FieldName)))
        {
          print " checked='checked'";
        }
        print "/></td>\n";

        print "<td>", $self->CGI->escapeHTML($VM->Name), "</td>\n";
        print "<td><details><summary>",
              $self->CGI->escapeHTML($VM->Description || $VM->Name),
              "$Status</summary>",
              $self->CGI->escapeHTML($VM->Details || "No details!"),
              "</details></td>";
        print "</tr>\n";
      }
      print "</tbody></table>\n";
    }
    else
    {
      if (defined($self->{NoCmdLineArgWarn}))
      {
        print "<div><input type='hidden' name='NoCmdLineArgWarn' value='on'>",
              "</div>\n";
      }
      my $VMs = CreateVMs();
      foreach my $VMKey (@{$VMs->GetKeys()})
      {
        my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
        if ($self->GetParam($FieldName))
        {
          print "<div><input type='hidden' name='$FieldName' value='on'>",
                "</div>\n";
        }
      }
    }
  }
  if ($self->{Page} == 4)
  {
    if ($self->GetParam("JobKey"))
    {
      $self->{JobKey} = $self->GetParam("JobKey");
    }
    print "<div><input type='hidden' name='JobKey' value='", $self->{JobKey},
          "'></div>\n";
  }

  $self->SUPER::GenerateFields();
}

sub GenerateActions($)
{
  my ($self) = @_;

  if ($self->{Page} == 2)
  {
    print <<EOF;
<script type='text/javascript'>
<!--
function ToggleAll()
{
  for (var i = 0; i < document.forms[0].elements.length; i++)
  {
    if(document.forms[0].elements[i].type == 'checkbox')
      document.forms[0].elements[i].checked = !(document.forms[0].elements[i].checked);
  }
}

// Only put javascript link in document if javascript is enabled
document.write("<div class='ItemActions'><a href='javascript:void(0)' onClick='ToggleAll();'>Toggle All<\\\/a><\\\/div>");
//-->
</script>
EOF

    print "<div class='ItemActions'>\n";
    print "<input type='submit' name='Action' value='",
          $self->{ShowAll} ? "Show base VMs" : "Show all VMs", "'/>\n";
    print "</div>\n";
  }

  $self->SUPER::GenerateActions();
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  if ($self->{Page} == 1)
  {
    push @$Actions, "Next >";
  }
  elsif ($self->{Page} == 2)
  {
    push @$Actions, "< Prev", "Next >";
  }
  elsif ($self->{Page} == 3)
  {
    push @$Actions, "< Prev", "Submit";
  }
  elsif ($self->{Page} == 4)
  {
    push @$Actions, "OK";
  }

  return $Actions;
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($self->{Page} == 3)
  {
    my $PropertyName = $PropertyDescriptor->GetName();
    if ($self->GetParam("FileType") eq "patchdlls")
    {
      if ($PropertyName eq "Run64")
      {
        my $Show64 = !1;
        my $VMs = CreateVMs();
        $VMs->AddFilter("Type", ["win64"]);
        foreach my $VMKey (@{$VMs->GetKeys()})
        {
          my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
          if ($self->GetParam($FieldName))
          {
            $Show64 = 1;
            last;
          }
        }
        if (! $Show64)
        {
          return "";
        }
      }
    }
    else
    {
      if ($PropertyName eq "TestExecutable" || $PropertyName eq "Run64")
      {
        return "";
      }
    }
  }

  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub GetPropertyValue($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($self->{Page} == 3)
  {
    my $PropertyName = $PropertyDescriptor->GetName();
    if ($PropertyName eq "DebugLevel")
    {
      return 1;
    }
    if ($PropertyName eq "Run64")
    {
      return 1;
    }
  }

  return $self->SUPER::GetPropertyValue($PropertyDescriptor);
}

sub GetTmpStagingFullPath($$)
{
  my ($self, $FileName) = @_;

  return undef if (!$FileName);
  return "$DataDir/staging/" . $self->GetCurrentSession()->Id . "-websubmit_$FileName";
}

sub Validate($)
{
  my ($self) = @_;

  if ($self->{Page} == 2 && $self->GetParam("Page") == 2)
  {
    my $VMSelected = !1;
    my $VMs = CreateVMs();
    foreach my $VMKey (@{$VMs->GetKeys()})
    {
      my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
      if ($self->GetParam($FieldName))
      {
        $VMSelected = 1;
        last;
      }
    }

    if (! $VMSelected)
    {
      $self->{ErrMessage} = "Select at least one VM";
      return !1;
    }
  }
  elsif ($self->{Page} == 3 && $self->GetParam("Page") == 3)
  {
    if (($self->GetParam("FileType") eq "patchdlls" &&
         $self->GetParam("TestExecutable") !~ m/^[\w_.]+_test\.exe$/) ||
        ($self->GetParam("TestExecutable") =~ m=(?:[a-z]:|[/\\])=i))
    {
      $self->{ErrField} = "TestExecutable";
      $self->{ErrMessage} = "Invalid test executable filename";
      return !1;
    }

    if ($self->GetParam("NoCmdLineArgWarn"))
    {
      $self->{NoCmdLineArgWarn} = 1;
    }
    elsif (! $self->GetParam("CmdLineArg"))
    {
      $self->{ErrMessage} = "You didn't specify a command line argument. " .
                            "This is most likely not correct, so please " .
                            "fix this. If you're sure that you really don't " .
                            'want a command line argument, press "Submit" ' .
                            "again.";
      $self->{ErrField} = "CmdLineArg";
      $self->{NoCmdLineArgWarn} = 1;
      return !1;
    }
  }

  return $self->SUPER::Validate();
}

sub ValidateAndGetFileName($$)
{
  my ($self, $FieldName) = @_;

  my $FileName = $self->GetParam($FieldName);
  if (!$FileName)
  {
    $self->{ErrField} = $FieldName;
    $self->{ErrMessage} = "You must provide a file to test";
    return undef;
  }
  if (!IsValidFileName($FileName))
  {
    $self->{ErrField} = $FieldName;
    $self->{ErrMessage} = "The filename contains invalid characters";
    return undef;
  }
  my $PropertyDescriptor = CreateSteps()->GetPropertyDescriptorByName("FileName");
  if ($PropertyDescriptor->GetMaxLength() - 32 - 1 < length($FileName))
  {
    $self->{ErrField} = $FieldName;
    $self->{ErrMessage} = "The filename is too long";
    return undef;
  }
  return $FileName;
}

sub DetermineFileType($$)
{
  my ($self, $FileName) = @_;

  if (! sysopen(FH, $FileName, O_RDONLY))
  {
    return ("Unable to open $FileName", "unknown", undef, undef);
  }

  my $FileType = "unknown";
  my $Buffer;
  if (sysread(FH, $Buffer, 0x40))
  {
    # Unpack IMAGE_DOS_HEADER
    my @Fields = unpack "S30I", $Buffer;
    if ($Fields[0] == 0x5a4d)
    {
      seek FH, $Fields[30], SEEK_SET;
      if (sysread(FH, $Buffer, 0x18))
      {
        @Fields = unpack "IS2I3S2", $Buffer;
        if ($Fields[0] == 0x00004550)
        {
          if (($Fields[7] & 0x2000) == 0)
          {
            $FileType = "exe";
          }
          else
          {
            $FileType = "dll";
          }
          if ($Fields[1] == 0x014c)
          {
            $FileType .= "32";
          }
          elsif ($Fields[1] == 0x8664)
          {
            $FileType .= "64";
          }
          else
          {
            $FileType = "unknown";
          }
        }
      }
    }
    # zip files start with PK, 0x03, 0x04
    elsif ($Fields[0] == 0x4b50 && $Fields[1] == 0x0403)
    {
      $FileType = "zip";
    }
  }

  close FH;

  my ($ErrMessage, $ExeBase, $TestUnit);
  if ($FileType eq "unknown")
  {
    my $Impacts = GetPatchImpact($FileName);
    if ($Impacts->{UnitCount} == 0)
    {
      $ErrMessage = "Patch doesn't affect tests";
    }
    elsif ($Impacts->{UnitCount} > 1)
    {
      $ErrMessage = "Patch contains changes to multiple tests";
    }
    else
    {
      my $TestInfo = (values %{$Impacts->{Tests}})[0];
      $FileType = "patchdlls";
      $ExeBase = $TestInfo->{ExeBase};
      $TestUnit = (keys %{$TestInfo->{Units}})[0];
    }
  }
  elsif ($FileType eq "dll32" || $FileType eq "dll64" || $FileType eq "zip")
  {
    # We know what these are but not what to do with them. So reject them early.
    $FileType = "unknown";
  }

  return ($ErrMessage, $FileType, $ExeBase, $TestUnit);
}

sub OnPage1Next($)
{
  my ($self) = @_;

  my $BaseName = $self->ValidateAndGetFileName("File");
  return !1 if (!$BaseName);

  my $Fh = $self->CGI->upload("File");
  if (defined($Fh))
  {
    my $StagingFile = $self->GetTmpStagingFullPath($BaseName);
    my $OldUMask = umask(002);
    if (! open (OUTFILE,">$StagingFile"))
    {
      umask($OldUMask);
      $self->{ErrField} = "File";
      $self->{ErrMessage} = "Unable to process uploaded file";
      return !1;
    }
    umask($OldUMask);
    my $Buffer;
    while (sysread($Fh, $Buffer, 4096))
    {
      print OUTFILE $Buffer;
    }
    close OUTFILE;

    my ($ErrMessage, $FileType, $ExeBase, $TestUnit) = $self->DetermineFileType($StagingFile);
    if (defined($ErrMessage))
    {
      $self->{ErrField} = "File";
      $self->{ErrMessage} = $ErrMessage;
      return !1;
    }
    if ($FileType !~ /^(?:exe32|exe64|patchdlls)$/)
    {
      $self->{ErrField} = "File";
      $self->{ErrMessage} = "Unrecognized file type";
      return !1;
    }

    $self->{FileName} = $BaseName;
    $self->{FileType} = $FileType;
    if (defined $ExeBase)
    {
      $self->{TestExecutable} = "$ExeBase.exe";
    }
    if (defined($TestUnit))
    {
      $self->{CmdLineArg} = $TestUnit;
    }
  }
  else
  {
    $self->{ErrField} = "File";
    $self->{ErrMessage} = "File upload failed";
    return !1;
  }

  if (! $self->Validate)
  {
    return !1;
  }

  $self->{Page} = 2;

  return 1;
}

sub OnPage2Next($)
{
  my ($self) = @_;

  if (! $self->Validate)
  {
    return !1;
  }

  $self->{Page} = 3;

  return 1;
}

sub OnNext($)
{
  my ($self) = @_;

  return $self->{Page} == 2 ? $self->OnPage2Next() : $self->OnPage1Next();
}

sub OnPage2Prev($)
{
  my ($self) = @_;

  my $FileName = $self->GetParam("File");
  if ($FileName)
  {
    my $StagingFileName = $self->GetTmpStagingFullPath(basename($FileName));
    unlink($StagingFileName) if ($StagingFileName);
  }

  $self->{Page} = 1;

  return 1;
}

sub OnPage3Prev($)
{
  my ($self) = @_;

  $self->{Page} = 2;

  return 1;
}

sub OnPrev($)
{
  my ($self) = @_;

  return $self->{Page} == 3 ? $self->OnPage3Prev() : $self->OnPage2Prev();
}

sub OnSubmit($)
{
  my ($self) = @_;

  return !1 if (!$self->Validate());
  my $BaseName = $self->ValidateAndGetFileName("FileName");
  return !1 if (!$BaseName);

  # See also Patches::Submit() in lib/WineTestBot/Patches.pm

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User($self->GetCurrentSession()->User);
  $NewJob->Priority(5);
  if ($self->GetParam("Remarks"))
  {
    $NewJob->Remarks($self->GetParam("Remarks"));
  }
  else
  {
    $NewJob->Remarks($self->GetParam("CmdLineArg"));
  }
  my $Branch = CreateBranches()->GetItem($self->GetParam("Branch"));
  if (defined($Branch))
  {
    $NewJob->Branch($Branch);
  }
  my $Steps = $NewJob->Steps;

  # Add steps and tasks for the 32 and 64-bit tests
  my $FileType = $self->GetParam("FileType");
  my $BuildStep;
  foreach my $Bits ("32", "64")
  {
    next if ($Bits eq "32" && $FileType eq "exe64");
    next if ($Bits eq "64" && $FileType eq "exe32");
    next if ($Bits eq "64" && $FileType eq "patchdlls" && !defined($self->GetParam("Run64")));

    my $Tasks;
    my $VMs = CreateVMs();
    $VMs->AddFilter("Type", $Bits eq "32" ? ["win32", "win64"] : ["win64"]);
    my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
    foreach my $VMKey (@$SortedKeys)
    {
      my $VM = $VMs->GetItem($VMKey);
      my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
      next if (!$self->GetParam($FieldName)); # skip unselected VMs

      if (!$Tasks)
      {
        if (!$BuildStep and $FileType eq "patchdlls")
        {
          # This is a patch so add a build step...
          $BuildStep = $Steps->Add();
          $BuildStep->FileName($BaseName);
          $BuildStep->FileType($FileType);
          $BuildStep->InStaging(!1);
          $BuildStep->Type("build");
          $BuildStep->DebugLevel(0);

          # ...with a build task
          my $VMs = CreateVMs();
          $VMs->AddFilter("Type", ["build"]);
          $VMs->AddFilter("Role", ["base"]);
          my $BuildVM = ${$VMs->GetItems()}[0];
          my $Task = $BuildStep->Tasks->Add();
          $Task->VM($BuildVM);
          $Task->Timeout($BuildTimeout);

          # Save the build step so the others can reference it
          my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
          if (defined($ErrMessage))
          {
            $self->{ErrMessage} = $ErrMessage;
            return !1;
          }
        }

        # Then create the test step
        my $TestStep = $Steps->Add();
        if ($FileType eq "patchdlls")
        {
          $TestStep->PreviousNo($BuildStep->No);
          my $TestExe = basename($self->GetParam("TestExecutable"));
          $TestExe =~ s/_test\.exe$/_test64.exe/ if ($Bits eq "64");
          $TestStep->FileName($TestExe);
        }
        else
        {
          $TestStep->FileName($BaseName);
        }
        $TestStep->InStaging(!1);
        $TestStep->FileType("exe$Bits");
        $TestStep->Type("single");
        $TestStep->DebugLevel($self->GetParam("DebugLevel"));
        $TestStep->ReportSuccessfulTests(defined($self->GetParam("ReportSuccessfulTests")));
        $Tasks = $TestStep->Tasks;
      }

      # Then add a task for this VM
      my $Task = $Tasks->Add();
      $Task->VM($VM);
      $Task->Timeout($SingleTimeout);
      $Task->CmdLineArg($self->GetParam("CmdLineArg"));
    }
  }

  # Now save it all (or whatever's left to save)
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  # Stage the test patch/executable so the job can pick it up
  my $TmpStagingFullPath = $self->GetTmpStagingFullPath($BaseName);
  if (!rename($TmpStagingFullPath, "$DataDir/staging/job". $NewJob->Id ."_$BaseName"))
  {
    $self->{ErrMessage} = "Could not stage '$BaseName': $!\n";
    return !1;
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  # Notify engine
  my $ErrMessage = RescheduleJobs();
  if (defined $ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    $self->{Page} = 4;
    $self->{JobKey} = $NewJob->GetKey();
    return !1;
  }

  $self->Redirect("/JobDetails.pl?Key=". $NewJob->GetKey()); # does not return
  exit;
}

sub OnShowAllVMs($)
{
  my ($self) = @_;

  $self->{ShowAll} = 1;

  return !1;
}

sub OnShowBaseVMs($)
{
  my ($self) = @_;

  $self->{ShowAll} = !1;

  return !1;
}

sub OnOK($)
{
  my ($self) = @_;

  if (defined($self->GetParam("JobKey")))
  {
    $self->Redirect("/JobDetails.pl?Key=" . $self->GetParam("JobKey")); # does not return
  }
  else
  {
    $self->Redirect("/index.pl"); # does not return
  }
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Next >")
  {
    return $self->OnNext();
  }
  elsif ($Action eq "< Prev")
  {
    return $self->OnPrev();
  }
  elsif ($Action eq "Submit")
  {
    return $self->OnSubmit();
  }
  elsif ($Action eq "Show base VMs")
  {
    return $self->OnShowBaseVMs();
  }
  elsif ($Action eq "Show all VMs")
  {
    return $self->OnShowAllVMs();
  }
  elsif ($Action eq "OK")
  {
    return $self->OnOK();
  }

  return $self->SUPER::OnAction($Action);
}


package main;

my $Request = shift;

my $SubmitPage = SubmitPage->new($Request, "wine-devel");
$SubmitPage->GeneratePage();
