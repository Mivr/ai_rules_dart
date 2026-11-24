/// Library constant evaluated from a comma-containing `-D` define.
const libCommaVal = String.fromEnvironment('COMMA_VAL', defaultValue: 'UNSET');
const libCommaEq = libCommaVal == 'a,b';
