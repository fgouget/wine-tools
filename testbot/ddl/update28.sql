USE winetestbot;

CREATE TABLE RecordGroups
(
  Id           INT(5) NOT NULL AUTO_INCREMENT,
  Timestamp    DATETIME NOT NULL,
  PRIMARY KEY (Id)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Records
(
  RecordGroupId INT(5) NOT NULL,
  Type         ENUM('engine', 'tasks', 'vmresult', 'vmstatus') NOT NULL,
  Name         VARCHAR(96) NOT NULL,
  Value        VARCHAR(64) NULL,
  PRIMARY KEY (RecordGroupId, Type, Name),
  FOREIGN KEY (RecordGroupId) REFERENCES RecordGroups(Id)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;
