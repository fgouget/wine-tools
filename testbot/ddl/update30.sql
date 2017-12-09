USE winetestbot;

ALTER TABLE Steps
  ADD PreviousNo INT(2) NULL
      AFTER No,
  ADD FOREIGN KEY (JobId, PreviousNo) REFERENCES Steps(JobId, No);

UPDATE Steps
  SET PreviousNo = 1
  WHERE No > 1;
