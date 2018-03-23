# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Base class for list blocks
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

=head1 NAME

ObjectModel::CGI::CollectionBlock - Base class for list blocks

=cut

package ObjectModel::CGI::CollectionBlock;

use POSIX qw(strftime);
use URI::Escape;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);

@EXPORT = qw(new);

sub new($$$@)
{
  my $class = shift;
  my ($Collection, $EnclosingPage) = @_;

  my $self = {Collection => $Collection,
              EnclosingPage => $EnclosingPage};
  $self = bless $self, $class;
  $self->_initialize(@_);
  return $self;
}

sub _initialize($$$)
{
  #my ($self, $Collection, $EnclosingPage) = @_;
}

sub escapeHTML($$)
{
  my ($self, $String) = @_;

  return $self->{EnclosingPage}->escapeHTML($String);
}

sub GenerateList($)
{
  my ($self) = @_;

  my $Collection = $self->{Collection};
  my $PropertyDescriptors = $Collection->GetPropertyDescriptors();
  my $HasDT = !1;
  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    if ($PropertyDescriptor->GetClass() eq "Basic" &&
        $PropertyDescriptor->GetType() eq "DT")
    {
      $HasDT = 1;
    }
  }
  if ($HasDT)
  {
  print <<"EOF";
<script type='text/javascript'><!--\
function Pad2(n)
{
    return n < 10 ? '0' + n : n;
}
function ShowDateTime(Sec1970)
{
  var Dt = new Date(Sec1970 * 1000);
  document.write(Dt.getFullYear() + '/' + Pad2(Dt.getMonth() + 1) + '/' +
                 Pad2(Dt.getDate()) + ' ' + Pad2(Dt.getHours()) + ':' +
                 Pad2(Dt.getMinutes()) + ':' + Pad2(Dt.getSeconds()));
}
//--></script>
EOF
  }

  print "<div class='CollectionBlock'>\n";
  $self->CallGenerateFormStart();
  $self->CallGenerateErrorDiv();

  print "<table border='0' cellpadding='5' cellspacing='0' summary='" .
        "Overview of " . $Collection->GetCollectionName() . "'>\n";
  print "<tbody>\n";
  my $Actions = $self->CallGetItemActions();
  $self->CallGenerateHeaderRow($PropertyDescriptors, $Actions);

  my $DetailsPage = $self->CallGetDetailsPage();
  my $Row = 0;
  my $Keys = $self->CallSortKeys($self->{Collection}->GetKeys());
  foreach my $Key (@$Keys)
  {
    my $Class = ($Row % 2) == 0 ? "even" : "odd";
    my $Item = $self->{Collection}->GetItem($Key);
    $self->CallGenerateDataRow($Item, $PropertyDescriptors, $DetailsPage,
                               $Class, $Actions);
    $Row++;
  }
  if (@$Keys == 0)
  {
    print "<tr class='even'><td colspan='0'>No entries</td></tr>\n";
  }

  print "</tbody>\n";
  print "</table>\n";

  if (@$Actions != 0 && @$Keys != 0)
  {
    print <<EOF;
<div class='CollectionBlockActions'>
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
document.write("<a href='javascript:void(0)' onClick='ToggleAll();'>Toggle All<\\\/a>&nbsp;");
//-->
</script>
EOF
    print "For selected ", $self->{Collection}->GetCollectionName() . ":";
    foreach my $Action (@$Actions)
    {
      print " <input type='submit' name='Action' value='" .
            $self->escapeHTML($Action) . "' />";
    }
    print "\n";
    print "</div>\n";
  }

  $Actions = $self->CallGetActions();
  if (@$Actions != 0)
  {
    print "<div class='CollectionBlockActions'>\n";
    foreach my $Action (@$Actions)
    {
      print "<input type='submit' name='Action' value='$Action' />\n";
    }
    print "</div>\n";
  }

  $self->CallGenerateErrorPopup(undef);
  $self->CallGenerateFormEnd();
  print "</div>\n";
}

sub CallGenerateFormStart($)
{
  my ($self) = @_;

  $self->GenerateFormStart();
}

sub GenerateFormStart($)
{
  my ($self) = @_;

  print "<form action='" . $ENV{"SCRIPT_NAME"} . "' method='post'>\n";
  my ($MasterColNames, $MasterColValues) = $self->{Collection}->GetMasterCols();
  if (defined($MasterColNames))
  {
    foreach my $ColIndex (0..scalar @$MasterColNames - 1)
    {
      print "<div><input type='hidden' name='", $MasterColNames->[$ColIndex],
            "' value='", $self->escapeHTML($MasterColValues->[$ColIndex]),
            "' /></div>\n";
    }
  }
}

sub CallGenerateErrorDiv($)
{
  my ($self) = @_;

  $self->{EnclosingPage}->GenerateErrorDiv();
}

sub CallGenerateErrorPopup($)
{
  my ($self) = @_;

  $self->{EnclosingPage}->GenerateErrorPopup();
}

sub CallGenerateFormEnd($)
{
  my ($self) = @_;

  $self->GenerateFormEnd();
}

sub GenerateFormEnd($)
{
  #my ($self) = @_;
  print "</form>\n";
}

sub CallGenerateHeaderRow($$$)
{
  my ($self, $PropertyDescriptors, $Actions) = @_;

  $self->GenerateHeaderRow($PropertyDescriptors, $Actions);
}

sub GenerateHeaderRow($$$)
{
  my ($self, $PropertyDescriptors, $Actions) = @_;

  print "<tr>\n";
  if (@$Actions != 0)
  {
    print "<th>&nbsp;</th>\n";
  }
  foreach my $PropertyDescriptor (@$PropertyDescriptors)
  {
    if ($self->CallDisplayProperty($PropertyDescriptor))
    {
      print "<th>", $self->escapeHTML($PropertyDescriptor->GetDisplayName()),
            "</th>\n";
    }
  }

  print "</tr>\n";
}

sub CallGenerateDataRow($$$$$$)
{
  my ($self, $Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions) = @_;

  $self->GenerateDataRow($Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions);
}

sub SelName($$)
{
  my ($self, $Key) = @_;

  $Key =~ s/[^0-9a-zA-Z]+/_/g;
  return "sel_" . $Key;
}

sub GenerateDataRow($$$$$$)
{
  my ($self, $Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions) = @_;

  print "<tr class='$Class'>\n";
  if (@$Actions != 0)
  {
    print "<td><input name='", $self->SelName($Item->GetKey()),
          "' type='checkbox' /></td>\n";
  }
  foreach my $PropertyDescriptor (@$PropertyDescriptors)
  {
    if ($self->CallDisplayProperty($PropertyDescriptor))
    {
      $self->CallGenerateDataCell($Item, $PropertyDescriptor, $DetailsPage);
    }
  }
  print "</tr>\n";
}

sub CallGenerateDataCell($$$$)
{
  my ($self, $Item, $PropertyDescriptor, $DetailsPage) = @_;

  return $self->GenerateDataCell($Item, $PropertyDescriptor, $DetailsPage);
}

sub GenerateDataCell($$$$)
{
  my ($self, $Item, $PropertyDescriptor, $DetailsPage) = @_;

  print "<td>";
  my $NeedLink;
  if ($PropertyDescriptor->GetIsKey() && $DetailsPage)
  {
    $NeedLink = 1;
  }
  else
  {
    $NeedLink = !1;
  }
  if ($NeedLink)
  {
    my $Query = "$DetailsPage?Key=" . uri_escape($Item->GetKey());
    my ($MasterColNames, $MasterColValues) = $Item->GetMasterCols();
    if (defined($MasterColNames))
    {
      foreach my $ColIndex (0 .. @$MasterColNames - 1)
      {
        $Query .= "&" . $MasterColNames->[$ColIndex] . "=" .
                  uri_escape($MasterColValues->[$ColIndex]);
      }
    }
    print "<a href='", $self->escapeHTML($Query), "'>";
  }
  print $self->CallGetEscapedDisplayValue($Item, $PropertyDescriptor);
  if ($NeedLink)
  {
    print "</a>";
  }
  print "</td>\n";
}

sub CallGetDetailsPage($)
{
  my ($self) = @_;

  return $self->GetDetailsPage();
}

sub GetDetailsPage($)
{
  my ($self) = @_;

  return $self->{Collection}->GetItemName() . "Details.pl";
}

sub CallGetItemActions($)
{
  my ($self) = @_;

  return $self->GetItemActions();
}

sub GetItemActions($)
{
  #my ($self) = @_;
  return ["Delete"];
}

sub CallGetActions($)
{
  my ($self) = @_;

  return $self->GetActions();
}

sub GetActions($)
{
  my ($self) = @_;

  my @Actions;
  if ($self->CallGetDetailsPage())
  {
    $Actions[0] = "Add " . $self->{Collection}->GetItemName();
  }
  my ($MasterColNames, $MasterColValues) = $self->{Collection}->GetMasterCols();
  if (defined($MasterColNames))
  {
    push @Actions, "Cancel";
  }

  return \@Actions;
}

sub CallDisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $self->DisplayProperty($PropertyDescriptor);
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $PropertyDescriptor->GetClass ne "Detailref";
}

sub CallGetEscapedDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  return $self->GetEscapedDisplayValue($Item, $PropertyDescriptor);
}

sub CallGetDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  return $self->GetDisplayValue($Item, $PropertyDescriptor);
}

sub GetDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  my $Value = $Item->$PropertyName;

  if ($PropertyDescriptor->GetClass() eq "Itemref")
  {
    if (defined($Value))
    {
      foreach $PropertyDescriptor (@{$Value->GetPropertyDescriptors()})
      {
        if ($PropertyDescriptor->GetIsKey())
        {
          $PropertyName = $PropertyDescriptor->GetName();
          $Value = $Value->$PropertyName;
          last;
        }
      }
    }
  }

  if ($PropertyDescriptor->GetClass() eq "Basic")
  {
    if ($PropertyDescriptor->GetType() eq "B")
    {
      $Value = ($Value ? "Yes" : "No");
    }
    elsif ($PropertyDescriptor->GetType() eq "DT")
    {
      if (defined($Value))
      {
$Value = 
         "<noscript><div>" .
         strftime("%Y/%m/%d %H:%M:%S", localtime($Value)) . "</div></noscript>\n" .
"<script type='text/javascript'><!--\n" .
         "ShowDateTime($Value);\n" .
         "//--></script>\n";
      }
    }
  }

  return $Value;
}

sub GetEscapedDisplayValue($$$)
{
  my ($self, $Item, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  my $Value = $Item->$PropertyName;

  if ($PropertyDescriptor->GetClass() eq "Basic" &&
      $PropertyDescriptor->GetType() eq "DT")
  {
    if (defined($Value))
    {
      $Value = "<script type='text/javascript'><!--\n" .
               "ShowDateTime($Value);\n" .
               "//--></script><noscript><div>" .
               strftime("%Y/%m/%d %H:%M:%S", localtime($Value)) .
               "</div></noscript>\n";
    }
  }
  else
  {
    $Value = $self->escapeHTML($self->CallGetDisplayValue($Item,
                                                          $PropertyDescriptor));
  }

  return $Value;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Cancel")
  {
#TODO
  }
  elsif ($Action eq "Add " . $self->{Collection}->GetItemName())
  {
    my $Target = $self->CallGetDetailsPage();
    my ($MasterColNames, $MasterColValues) = $self->{Collection}->GetMasterCols();
    if (defined($MasterColNames))
    {
      foreach my $ColIndex (0 .. @$MasterColNames - 1)
      {
        $Target .= ($ColIndex == 0 ? "?" : "&") . $MasterColNames->[$ColIndex] .
                   "=" . uri_escape($MasterColValues->[$ColIndex]);
      }
    }
    $self->{EnclosingPage}->Redirect($Target);
    return 1;
  }
  else
  {
    my $Ok = 1;
    foreach my $Key (@{$self->{Collection}->GetKeys()})
    {
      if (defined($self->{EnclosingPage}->GetParam($self->SelName($Key))) &&
          $Ok)
      {
        my $Item = $self->{Collection}->GetItem($Key);
        $Ok = $self->CallOnItemAction($Item, $Action);
      }
    }
  }
}

sub CallOnItemAction($$$)
{
  my ($self, $Item, $Action) = @_;

  return $self->OnItemAction($Item, $Action);
}

sub OnItemAction($$$)
{
  my ($self, $Item, $Action) = @_;

  if ($Action eq "Delete")
  {
    my $ErrMessage = $self->{Collection}->DeleteItem($Item);
    $self->{EnclosingPage}->{ErrMessage} = $ErrMessage;
    return ! defined($ErrMessage);
  }

  return 1;
}

sub CallSortKeys($$)
{
  my ($self, $Keys) = @_;

  return $self->SortKeys($Keys);
}

sub SortKeys($$)
{
  my ($self, $Keys) = @_;

  return $Keys;
}

1;
