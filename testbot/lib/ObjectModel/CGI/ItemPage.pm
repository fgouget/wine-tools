# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Base class for web pages containing a db bound form
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

ObjectModel::CGI::ItemPage - Base class for bound web forms

=cut

package ObjectModel::CGI::ItemPage;

use URI::Escape;
use ObjectModel::CGI::FormPage;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::CGI::FormPage Exporter);

sub _initialize($$$$)
{
  my ($self, $Request, $RequiredRole, $Collection) = @_;

  $self->{Collection} = $Collection;

  $self->SUPER::_initialize($Request, $RequiredRole, $Collection->GetPropertyDescriptors());

  if (defined($self->GetParam("Key")))
  {
    $self->{Item} = $Collection->GetItem($self->GetParam("Key"));
  }
  else
  {
    $self->{Item} = undef;
  }
  if (! defined($self->{Item}))
  {
    $self->{Item} = $Collection->Add();
  }
}

sub GenerateFormStart($)
{
  my ($self) = @_;

  $self->SUPER::GenerateFormStart();

  my ($MasterColNames, $MasterColValues) = $self->{Collection}->GetMasterCols();
  if (defined($MasterColNames))
  {
    foreach my $ColIndex (0 .. @$MasterColNames)
    {
      print "<div><input type='hidden' name='", $MasterColNames->[$ColIndex],
            "' value='", $self->escapeHTML($MasterColValues->[$ColIndex]),
            "' /></div>\n";
    }
  }
  if (! $self->{Item}->GetIsNew())
  {
      print "<div><input type='hidden' name='Key' value='",
            $self->escapeHTML($self->{Item}->GetKey()), "' /></div>\n";
  }
}

sub GetPropertyValue($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return $self->{Item}->$PropertyName;
}

sub GetTitle($)
{
  my ($self) = @_;

  return $self->GetParam("Key") ? $self->GetParam("Key") :
             "Add " . $self->{Collection}->GetItemName();
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $Display = $self->SUPER::DisplayProperty($PropertyDescriptor);
  if ($Display eq "rw" && ! $self->{Item}->GetIsNew() &&
      $PropertyDescriptor->GetIsKey())
  {
    $Display = "";
  }

  return $Display;
}

sub GetActions($)
{
  my ($self) = @_;

  my @Actions = @{$self->SUPER::GetActions()};
  $Actions[@Actions] = "OK";
  $Actions[@Actions] = "Cancel";

  return \@Actions;
}

sub SaveProperty($$$)
{
  my ($self, $PropertyDescriptor, $Value) = @_;

  if ($PropertyDescriptor->GetClass() eq "Basic" &&
      $PropertyDescriptor->GetType() eq "B" && $Value)
  {
    $Value = 1;
  }

  my $PropertyName = $PropertyDescriptor->GetName();
  $self->{Item}->$PropertyName($Value);

  return 1;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "OK")
  {
    return !1 if (!$self->Save());
    $self->RedirectToList();
    exit;
  }
  elsif ($Action eq "Cancel")
  {
    $self->RedirectToList();
    exit;
  }

  return $self->SUPER::OnAction($Action);
}

sub RedirectToList($)
{
  my ($self) = @_;

  my $Target = $self->{Collection}->GetCollectionName() . "List.pl";
  my ($MasterColNames, $MasterColValues) = $self->{Collection}->GetMasterCols();
  if (defined($MasterColNames))
  {
    foreach my $ColIndex (0 .. @$MasterColNames - 1)
    {
      $Target .= ($ColIndex == 0 ? "?" : "&") . $MasterColNames->[$ColIndex] .
                 "=" . url_escape($MasterColValues->[$ColIndex]);
    }
  }
  $self->Redirect($Target); # does not return
}

1;
