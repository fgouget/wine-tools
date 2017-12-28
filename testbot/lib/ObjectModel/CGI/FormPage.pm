# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Base class for web pages containing a form
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012 Francois Gouget
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

=head1 NAME

ObjectModel::CGI::FormPage - Base class for web forms

=cut

package ObjectModel::CGI::FormPage;

use ObjectModel::CGI::Page;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::CGI::Page Exporter);

sub _initialize($$$$)
{
  my ($self, $Request, $RequiredRole, $PropertyDescriptors) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole);

  $self->{PropertyDescriptors} = $PropertyDescriptors;
  $self->{HasRequired} = !1;
  $self->{ActionPerformed} = !1;
}

sub GetPropertyDescriptors($)
{
  my ($self) = @_;

  return $self->{PropertyDescriptors};
}

sub GetPropertyDescriptorByName($$)
{
  my ($self, $Name) = @_;

  my $PropertyDescriptors = $self->GetPropertyDescriptors();
  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    if ($PropertyDescriptor->GetName() eq $Name)
    {
      return $PropertyDescriptor;
    }
  }

  return undef;
}

sub GeneratePage($)
{
  my ($self) = @_;

  if ($self->GetParam("Action"))
  {
    $self->{ActionPerformed} = $self->OnAction($self->GetParam("Action"));
  }

  $self->SUPER::GeneratePage();
}

sub GenerateTitle($)
{
  my ($self) = @_;

  my $Title = $self->GetTitle();
  if ($Title)
  {
    print "<h1>", $self->CGI->escapeHTML($Title), "</h1>\n";
  }
}

sub GenerateBody($)
{
  my ($self) = @_;

  print "<div class='ItemBody'>\n";
  $self->GenerateTitle();
  print "<div class='Content'>\n";
  my $Text = $self->GetHeaderText();
  if ($Text)
  {
    print "<p>$Text</p>\n";
  }
  $self->GenerateFormStart();
  $self->GenerateErrorDiv();

  $self->GenerateFields();
  $self->GenerateRequiredLegend();

  if (defined($self->{ErrMessage}))
  {
    my $PropertyDescriptor;
    if (defined($self->{ErrField}))
    {
      $PropertyDescriptor = $self->GetPropertyDescriptorByName($self->{ErrField});
    }
    if (! defined($PropertyDescriptor) ||
        $self->DisplayProperty($PropertyDescriptor))
    {
      $self->GenerateErrorPopup();
    }
  }
  $self->GenerateActions();
  $self->GenerateFormEnd();
  $Text = $self->GetFooterText();
  if ($Text)
  {
    print "<p>$Text</p>\n";
  }
  print "</div>\n";
  print "</div>\n";
}

sub GenerateFormStart($)
{
  #my ($self) = @_;
  print "<form action='" . $ENV{"SCRIPT_NAME"} .
       "' method='post' enctype='multipart/form-data'>\n";
}

sub GenerateFields($)
{
  my ($self) = @_;

  my $PropertyDescriptors = $self->GetPropertyDescriptors();
  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    my $Display = $self->DisplayProperty($PropertyDescriptor);
    $self->GenerateField($PropertyDescriptor, $Display) if ($Display);
  }
}

sub GenerateRequiredLegend($)
{
  my ($self) = @_;

  if ($self->{HasRequired})
  {
    print "<div class='ItemProperty'><label><span class='Required'>*</span></label>Required field</div>\n";
  }
}

sub GenerateActions($)
{
  my ($self) = @_;

  print "<div class='ItemActions'>\n";
  foreach my $Action (@{$self->GetActions()})
  {
    print "<input type='submit' name='Action' value='$Action'/>\n";
  }
  print "</div>\n";
}

sub GenerateFormEnd($)
{
  #my ($self) = @_;
  print "</form>\n";
}

sub GetPropertyValue($$)
{
  #my ($self, $PropertyDescriptor) = @_;
  return undef;
}

sub GetDisplayValue($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $Value;
  if (defined($self->GetParam($PropertyDescriptor->GetName())))
  {
    $Value = $self->GetParam($PropertyDescriptor->GetName());
  }
  else
  {
    $Value = $self->GetPropertyValue($PropertyDescriptor);
  }

  return $Value;
}

sub GetDisplayName($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $PropertyDescriptor->GetDisplayName();
}

sub GetInputType($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $PropertyDescriptor->GetClass() eq "Enum" ? "select" :
         $PropertyDescriptor->GetType() eq "B" ? "checkbox" :
         $PropertyDescriptor->GetType() eq "textarea" ? "textarea" :
         "text";
}

sub GenerateField($$$)
{
  my ($self, $PropertyDescriptor, $Display) = @_;

  print "<div class='ItemProperty'><label>",
        $self->CGI->escapeHTML($self->GetDisplayName($PropertyDescriptor)) .
        "</label>";

  my $Value = $self->GetDisplayValue($PropertyDescriptor);
  if ($Display eq "rw")
  {
    my $InputType = $self->GetInputType($PropertyDescriptor);
    print "<div class='ItemValue'>";
    if ($InputType eq "checkbox")
    {
      print "<input type='checkbox' name='", $PropertyDescriptor->GetName(),
            "' ";
      if ($Value)
      {
        print "checked='checked' ";
      }
      print "/>";
    }
    elsif ($InputType eq "select")
    {
      print "<select name='", $PropertyDescriptor->GetName(), "'>\n";
      foreach my $V (@{$PropertyDescriptor->GetValues()})
      {
        print "  <option value='", $self->CGI->escapeHTML($V), "'";
        print " selected='selected'" if ($Value eq $V);
        print ">", $self->CGI->escapeHTML($V), "</option>\n";
      }
      print "</select>";
    }
    elsif ($InputType eq "textarea")
    {
      my $MaxLength = $PropertyDescriptor->GetMaxLength();
      print "<textarea name='", $PropertyDescriptor->GetName(), "' cols='";
      if ($MaxLength < 50)
      {
        print "$MaxLength' rows='1";
      }
      else
      {
        print "50' rows='", int(($MaxLength + 49) / 50);
      }
      print "'>";
      if ($Value)
      {
        print $self->CGI->escapeHTML($Value), "'";
      }
      print "</textarea>";
      $self->GenerateRequired($PropertyDescriptor);
    }
    else
    {
      my $Size=$PropertyDescriptor->GetMaxLength();
      $Size=45 if ($Size > 45);
      print "<input type='$InputType' name='", $PropertyDescriptor->GetName(),
            "' maxlength='", $PropertyDescriptor->GetMaxLength(), "' size='$Size'";
      if ($Value && $InputType ne "password")
      {
        print " value='", $self->CGI->escapeHTML($Value), "'";
      }
      print " />";
      $self->GenerateRequired($PropertyDescriptor);
    }
    print "</div>";
  }
  else
  {
    if ($Value)
    {
      print $self->CGI->escapeHTML($Value);
    }
    else
    {
      print "&nbsp;";
    }
  }

  print "</div>\n";
}

sub GenerateRequired($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetIsRequired())
  {
    $self->{HasRequired} = 1;
    print "&nbsp;<span class='Required'>*</span>";
  }
}

sub GetTitle($)
{
  #my ($self) = @_;
  return undef;
}

sub GetHeaderText($)
{
  #my ($self) = @_;
  return undef;
}

sub GetFooterText($)
{
  #my ($self) = @_;
  return undef;
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetClass() eq "Detailref")
  {
    return "";
  }

  return "rw";
}

sub GetActions($)
{
  #my ($self) = @_;
  return [];
}

sub SaveProperty($$$)
{
  #my ($self, $PropertyDescriptor, $Value) = @_;
  die "Pure virtual function FormPage::SaveProperty called";
}

sub SaveProperties($)
{
  my ($self) = @_;

  my @ParamNames = $self->GetParamNames();
  foreach my $ParameterName (@ParamNames)
  {
    my $PropertyDescriptor = $self->GetPropertyDescriptorByName($ParameterName);
    if (defined($PropertyDescriptor))
    {
      if (! $self->SaveProperty($PropertyDescriptor,
          $self->GetParam($ParameterName)))
      {
        return !1;
      }
    }
  }

  foreach my $PropertyDescriptor (@{$self->{Collection}->GetPropertyDescriptors})
  {
    if ($PropertyDescriptor->GetClass() eq "Basic" &&
        $PropertyDescriptor->GetType() eq "B" &&
        $self->DisplayProperty($PropertyDescriptor) eq "rw" &&
        ! defined($self->GetParam($PropertyDescriptor->GetName())))
    {
      if (! $self->SaveProperty($PropertyDescriptor, !1))
      {
        return !1;
      }
    }
  }
  return 1;
}

sub Save($)
{
  my ($self) = @_;

  return !1 if (!$self->SaveProperties());

  my $ErrKey;
  ($ErrKey, $self->{ErrField}, $self->{ErrMessage}) = $self->{Collection}->Save();
  return ! defined($self->{ErrMessage});
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  die "No action defined for $Action";
}

sub Validate($)
{
  my ($self) = @_;

  my $PropertyDescriptors = $self->GetPropertyDescriptors();
  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    my $Value = $self->GetParam($PropertyDescriptor->GetName());
    my $ErrMessage = $PropertyDescriptor->ValidateValue($Value, 1);
    if ($ErrMessage)
    {
      $self->{ErrMessage} = $ErrMessage;
      $self->{ErrField} = $PropertyDescriptor->GetName();
      return !1;
    }
  }

  return 1;
}

1;
