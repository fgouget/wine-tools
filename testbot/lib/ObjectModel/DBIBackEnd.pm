# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012, 2014 Francois Gouget
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

use DBI;
use ObjectModel::BackEnd;

package ObjectModel::DBIBackEnd;

=head1 NAME

ObjectModel::DBIBackEnd - A storage backend implemented using DBI

=head1 SEE ALSO

ObjectModel::BackEnd

=cut

use Time::Local;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::BackEnd Exporter);
@EXPORT = qw(&UseDBIBackEnd);

sub GetDb($)
{
  my ($self) = @_;

  if (defined $self->{Db} && !$self->{Db}->ping())
  {
    # This connection no longer works, probably due to the database idle timeout
    $self->{Db}->disconnect();
    $self->{Db} = undef;
  }
  if (!defined $self->{Db})
  {
    while (1)
    {
      # Protect this call so we can retry in case RaiseError is set
      eval { $self->{Db} = DBI->connect(@{$self->{ConnectArgs}}) };
      last if ($self->{Db});

      # Prints errors on stderr like DBI normally does
      $@ ||= "DBI::connect() returned undef without setting an error";
      print STDERR "$@\n";
      sleep(30);
    }
  }
  return $self->{Db};
}

sub ToDb($$$)
{
  my ($self, $Value, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetClass eq "Basic")
  {
    if ($PropertyDescriptor->GetType() eq "B")
    {
      if ($Value)
      {
        $Value = "Y";
      }
      else
      {
        $Value = "N";
      }
    }
    elsif ($PropertyDescriptor->GetType() eq "DT")
    {
      if (defined($Value))
      {
        if ($Value == 0)
        {
          $Value = undef;
        }
        else
        {
          my ($Sec, $Min, $Hour, $MDay, $Mon, $Year, $WDay, $YDay, $IsDst) = gmtime($Value);
          $Value = sprintf "%04d-%02d-%02d %02d:%02d:%02d",
                           $Year + 1900, $Mon + 1, $MDay, $Hour, $Min, $Sec;
        }
      }
    }
  }

  return $Value;
}

sub FromDb($$$)
{
  my ($self, $Value, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetClass eq "Basic")
  {
    if ($PropertyDescriptor->GetType() eq "B")
    {
      $Value = ($Value eq "Y");
    }
    elsif ($PropertyDescriptor->GetType() eq "DT")
    {
      if (defined($Value))
      {
        if ($Value eq "0000-00-00 00:00:00")
        {
          $Value = undef;
        }
        else
        {
          my ($Year, $Month, $Day, $Hour, $Min, $Sec) =
            ($Value =~ m/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/);
          $Value = timegm($Sec, $Min, $Hour, $Day, $Month - 1, $Year - 1900);
        }
      }
    }
  }

  return $Value;
}

sub BuildKeyWhere($$$$)
{
  my ($self, $PropertyDescriptors, $ColPrefix, $Where) = @_;

  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    if ($PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        if ($Where ne "")
        {
          $Where .= " AND ";
        }
        $Where .= $ColPrefix . $ColName . " = ?";
      }
    }
  }

  return $Where;
}

sub BuildFieldList($$)
{
  my ($self, $PropertyDescriptors) = @_;

  my $Fields = "";
  foreach my $PropertyDescriptor (@$PropertyDescriptors)
  {
    foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
    {
      if ($Fields ne "")
      {
        $Fields .= ", ";
      }
      $Fields .= $ColName;
    }
  }

  return $Fields;
}

my %_AllowedFilterTypes = (
  "="    => 1,
  "<>"   => 1,
  "<"    => 1,
  "<="   => 1,
  ">"    => 1,
  ">="   => 1,
  "LIKE" => 1,
);

sub LoadCollection($$)
{
  my ($self, $Collection) = @_;

  my $Fields = $self->BuildFieldList($Collection->GetPropertyDescriptors());

  my $Where = "";
  my @Data;
  my ($MasterColNames, $MasterColValues) = $Collection->GetMasterCols();
  if (defined($MasterColNames))
  {
    $Where = join(" = ? AND ", @{$MasterColNames}) . " = ?";
    push(@Data, @{$MasterColValues});
  }

  my $Filters = $Collection->GetFilters();
  foreach my $FilterProperty (keys %$Filters)
  {
    if ($Where ne "")
    {
      $Where .= " AND ";
    }
    my $PropertyDescriptor = $Collection->GetPropertyDescriptorByName($FilterProperty);
    my ($FilterType, $FilterValues) = @{$Filters->{$FilterProperty}};
    if (!$_AllowedFilterTypes{$FilterType})
    {
      die "unknown '$FilterType' filter type";
    }
    if (!@$FilterValues)
    {
      die "no values for the '$FilterType' filter";
    }

    if (@$FilterValues != 1)
    {
      $Where .= "(";
    }
    foreach my $FilterIndex (0 .. @$FilterValues - 1)
    {
      if ($FilterIndex != 0)
      {
        $Where .= " OR ";
      }
      my $ColValue = $FilterValues->[$FilterIndex];
      if ($PropertyDescriptor->GetClass() eq "Itemref")
      {
        $ColValue = $ColValue->GetKey();
      }
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $Where .= "$ColName $FilterType ?";
        $Data[@Data] = $self->ToDb($ColValue, $PropertyDescriptor);
      }
    }
    if (@$FilterValues != 1)
    {
      $Where .= ")";
    }
  }

  my $Query = "SELECT $Fields FROM " . $Collection->GetTableName();
  if ($Where ne "")
  {
    $Query .= " WHERE $Where";
  }
  my $Statement = $self->GetDb()->prepare($Query);
  $Statement->execute(@Data);

  while (my $Row = $Statement->fetchrow_hashref())
  {
    my $Item = $Collection->CreateItem();
    foreach my $PropertyDescriptor (@{$Collection->GetPropertyDescriptors()})
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $Item->PutColValue($ColName, $self->FromDb($Row->{$ColName},
                                                   $PropertyDescriptor));
      }
    }
    $Item->ResetModified();

    my $Key = $Item->GetKey();
    $Collection->{Items}{$Key} = $Collection->GetScopeItem($Key, $Item);
  }

  $Statement->finish();
}

=pod
=over 12

=item C<LoadItem()>

Loads the specified Item from the database and adds it to the Collection.
By design this method will not check if the Item is already present in the
Collection scope. Such checks belong in the higher levels. This method will
however put the Item in the Collection's scope.

=back
=cut

sub LoadItem($$$)
{
  my ($self, $Collection, $RequestedKey) = @_;

  my $Fields = $self->BuildFieldList($Collection->GetPropertyDescriptors());

  my $Where = "";
  my @Data;
  my ($MasterColNames, $MasterColValues) = $Collection->GetMasterCols();
  if (defined($MasterColNames))
  {
    $Where = join(" = ? AND ", @{$MasterColNames}) . " = ?";
    push(@Data, @{$MasterColValues});
  }
  $Where = $self->BuildKeyWhere($Collection->GetPropertyDescriptors(), "",
                                $Where);
  push(@Data, $Collection->SplitKey($RequestedKey));

  my $Query = "SELECT $Fields FROM " . $Collection->GetTableName();
  if ($Where ne "")
  {
    $Query .= " WHERE $Where";
  }
  my $Statement = $self->GetDb()->prepare($Query);
  $Statement->execute(@Data);

  my $Item;
  if (my $Row = $Statement->fetchrow_hashref())
  {
    $Item = $Collection->CreateItem();
    foreach my $PropertyDescriptor (@{$Collection->GetPropertyDescriptors()})
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $Item->PutColValue($ColName, $self->FromDb($Row->{$ColName},
                                                   $PropertyDescriptor));
      }
    }
    $Item->ResetModified();
    $Item = $Collection->GetScopeItem($RequestedKey, $Item);
  }

  $Statement->finish();

  return $Item;
}

sub BuildInsertStatement($$$$)
{
  my ($self, $TableName, $PropertyDescriptors, $MasterColNames) = @_;

  my $Fields = "";
  my $PlaceHolders = "";
  if (defined($MasterColNames))
  {
    foreach my $ColName (@$MasterColNames)
    {
      if ($Fields ne "")
      {
        $Fields .= ", ";
        $PlaceHolders .= ", ";
      }
      $Fields .= $ColName;
      $PlaceHolders .= "?";
    }
  }

  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
    {
      if ($Fields ne "")
      {
        $Fields .= ", ";
        $PlaceHolders .= ", ";
      }
      $Fields .= $ColName;
      $PlaceHolders .= "?";
    }
  }

  return "INSERT INTO $TableName ($Fields) VALUES($PlaceHolders)";
}

sub GetInsertData($$$)
{
  my ($self, $MasterColValues, $Item) = @_;

  my @Data;
  if (defined($MasterColValues))
  {
    push(@Data, @$MasterColValues);
  }

  foreach my $PropertyDescriptor (@{$Item->GetPropertyDescriptors()})
  {
    foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
    {
      $Data[@Data] = $self->ToDb($Item->GetColValue($ColName),
                                 $PropertyDescriptor);
    }
  }

  return \@Data;
}

sub BuildUpdateStatement($$$$)
{
  my ($self, $TableName, $PropertyDescriptors, $MasterColNames) = @_;

  my $Fields = "";
  foreach my $PropertyDescriptor (@{$PropertyDescriptors})
  {
    if (! $PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        if ($Fields ne "")
        {
          $Fields .= ", ";
        }
        $Fields .= $ColName . " = ?";
      }
    }
  }

  my $Where = "";
  if (defined($MasterColNames))
  {
    $Where = join(" = ? AND ", @{$MasterColNames}) . " = ?";
  }
  $Where = $self->BuildKeyWhere($PropertyDescriptors, "", $Where);

  return "UPDATE $TableName SET $Fields WHERE $Where";
}

sub GetUpdateData($$$)
{
  my ($self, $MasterColValues, $Item) = @_;

  my @Data;
  foreach my $PropertyDescriptor (@{$Item->GetPropertyDescriptors()})
  {
    if (! $PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $Data[@Data] = $self->ToDb($Item->GetColValue($ColName),
                                   $PropertyDescriptor);
      }
    }
  }

  if (defined($MasterColValues))
  {
    push(@Data, @$MasterColValues);
  }

  foreach my $PropertyDescriptor (@{$Item->GetPropertyDescriptors()})
  {
    if ($PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $Data[@Data] = $Item->GetColValue($ColName);
      }
    }
  }

  return \@Data;
}

sub SaveCollection($$)
{
  my ($self, $Collection) = @_;

  my $Db = $self->GetDb();
  my ($MasterColNames, $MasterColValues) = $Collection->GetMasterCols();
  my $UpdateQuery = $self->BuildUpdateStatement($Collection->GetTableName(),
                                                $Collection->GetPropertyDescriptors(),
                                                $MasterColNames);
  my $UpdateStatement = $Db->prepare($UpdateQuery);

  my $InsertQuery = $self->BuildInsertStatement($Collection->GetTableName(),
                                                $Collection->GetPropertyDescriptors(),
                                                $MasterColNames);
  my $InsertStatement = $Db->prepare($InsertQuery);

  foreach my $Key (@{$Collection->GetKeysNoLoad()})
  {
    my $Item = $Collection->GetItem($Key);
    if ($Item->GetIsNew())
    {
      $InsertStatement->execute(@{$self->GetInsertData($MasterColValues,
                                                       $Item)});

      foreach my $PropertyDescriptor (@{$Collection->{PropertyDescriptors}})
      {
        if ($PropertyDescriptor->GetIsKey() &&
            $PropertyDescriptor->GetClass() eq "Basic" &&
            $PropertyDescriptor->GetType() eq "S")
        {
          my $ColNames = $PropertyDescriptor->GetColNames;
          if (scalar @{$ColNames} != 1)
          {
            die "Sequence property spans multiple columns";
          }

          $Item->PutColValue(@{$ColNames}[0], $Db->{'mysql_insertid'});
          $Collection->KeyChanged($Key, $Item->GetKey());
        }
      }

      $Item->OnSaved();
    }
    elsif ($Item->GetIsModified())
    {
      $UpdateStatement->execute(@{$self->GetUpdateData($MasterColValues, $Item)});
      $Item->OnSaved();
    }
  }

  $InsertStatement->finish();
  $UpdateStatement->finish();
}

sub SaveItem($$)
{
  my ($self, $Item) = @_;

  my $Query;
  my ($MasterColNames, $MasterColValues) = $Item->GetMasterCols();
  if ($Item->GetIsModified())
  {
    $Query = $self->BuildUpdateStatement($Item->GetTableName(),
                                         $Item->GetPropertyDescriptors(),
                                         $MasterColNames);
  }
  elsif ($Item->GetIsNew())
  {
    die "Internal error: Need to save new items via collection";
  }
  else
  {
    return;
  }

  my $Statement = $self->GetDb()->prepare($Query);
  $Statement->execute(@{$self->GetUpdateData($MasterColValues, $Item)});

  $Statement->finish();
}

sub DeleteItem($$)
{
  my ($self, $Item) = @_;

  my $Where = "";
  my @Data;
  my ($MasterColNames, $MasterColValues) = $Item->GetMasterCols();
  if (defined($MasterColNames))
  {
    $Where = join(" = ? AND ", @{$MasterColNames}) . " = ?";
    push(@Data, @{$MasterColValues});
  }
  $Where = $self->BuildKeyWhere($Item->GetPropertyDescriptors(), "",
                                $Where);
  push(@Data, $Item->GetKeyComponents());

  my $Statement = $self->GetDb()->prepare("DELETE FROM " .
                                          $Item->GetTableName() .
                                          " WHERE " . $Where);
  $Statement->execute(@Data);
  $Statement->finish();

  return undef;
}

sub DeleteAll($$)
{
  my ($self, $Collection) = @_;

  my $Where = "";
  my @Data;
  my ($MasterColNames, $MasterColValues) = $Collection->GetMasterCols();
  if (defined($MasterColNames))
  {
    $Where = join(" = ? AND ", @{$MasterColNames}) . " = ?";
    push(@Data, @{$MasterColValues});
  }

  my $Query = "DELETE FROM " . $Collection->GetTableName();
  if ($Where ne "")
  {
    $Query .= " WHERE " . $Where;
  }
  my $Statement = $self->GetDb()->prepare($Query);
  $Statement->execute(@Data);
  $Statement->finish();

  return undef;
}

sub Close($)
{
  my ($self) = @_;

  if (defined($self->{Db}))
  {
    $self->{Db}->disconnect();
    $self->{Db} = undef;
  }
}

sub UseDBIBackEnd($$$$$$)
{
  my ($class, $DbSelector, $DbSource, $DbUser, $DbPassword, $DbArgs) = @_;

  my $BackEnd = $class->new();
  $BackEnd->{ConnectArgs} = [$DbSource, $DbUser, $DbPassword, $DbArgs];
  AddDBBackEnd($DbSelector, $BackEnd);
}
1;
