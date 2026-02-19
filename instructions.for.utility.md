
make this a commandline utility that can read log files that are text with each line containing serialized json object, otpionally prefixed with some text that can be ignored (look for first '{' in a line to assume json starts there and not required from first character)
- if parsing a line fails, ignore that line

the utility called  gtlogj should work by either
- reading a file
- reading stdin
- tailing a file

define a configuration file where options for what the utility does, how it displys results and input parameters
config file location will be provided as a param (-c --config)

config file can have multiple sections called [folders] so each fodlers section can have its global configuration,
and 
-  each fodlers sectioin can define multiple folder paths that it matches
- each fodlers section also has subsections for additional configurations profiles to be used in that folder
- when utility is called (-p --profile can be used to use config from that profile inside config matched for that folder)

Utility will have some keys from json with special meaning and those will allow to be configured
- timestamp - user can define name of the key that defines time for that log entry (code must recognize if timestamp is milisecond or unix timestamp) default name is `ts`
- level - user can define name of the key that defines  log level
- message - user can define name of the key that defines  log message
- thread - user can define name of the key that defines  log thread
- logger - user can define name of the key that defines  log logger 
- trace - user can define name of the key that defines  log stack trace

folders and profile of config will define pattern for output that is a list of keys with optional format specifiers

command line parameters
- -c --config - config file location
- -p --profile - profile to use from config file
- -f --file - file to read
- -i --stdin - read from stdin
- -t --tail - tail file
- -o --output - output file
- -r --raw - raw output (ouput lie as is, that means line string needs to be also in memory as text so after filtering based on key is done, it is output as is)
