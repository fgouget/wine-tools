USE winetestbot;

ALTER TABLE Patches
  ADD MessageId VARCHAR(256) NULL
      AFTER Subject;
