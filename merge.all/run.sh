#!/bin/bash

namePrefix=p4.merge.all
configFileName=$namePrefix.conf
stateFileName=$namePrefix.status

#
# === End of configuration ===
#

set -o pipefail

function usage() {
  cat <<EOF
Performes integrations as specified in "$configFileName".

Usage:
  $( basename $0 ) g[o] [-u] [-r] [-c configFileName]
  $( basename $0 ) c[ontinue] [-u] [-m] [-i <index>] [-r]

Actions:
  go        Start a new merge.
  continue  Continue an existing merge.

Options - global:
  -u  Unsafe - do not to stop before every commit.

Options - "go":
  -c configFileName
      Config - use a different config file.
      Default: $configFileName

  -r  Restart - delete old state file.

Options - "continue":
  -m  Ignore MD5 check of the configuration file.

  -i <index>
      Continue, starting from a different integration.
      This will discard pedning changelist created for the currently active
      integration if there is any.

  -r  Restart current integration step from the beginning.  This will discard
      pending changelist created for this integration if there is any.

EOF
}

function processArguments() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  action=$1
  shift

  safe=yes
  restart=
  ignoreMd5InState=
  startIntegrationIndex=
  if [[ $action = go || $action = g ]]; then
    # Normalize action name
    action=go
    while getopts ":c:ru" opt; do
      case $opt in
        c) configFileName=$OPTARG
          ;;
        r) restart=yes
          ;;
        u) safe=
          ;;

        \?)
          echo "Error: Unexpected argument: -$OPTARG"
          echo
          usage
          exit 1
      esac
    done
  elif [[ $action = continue || $action = c ]]; then
    # Normalize action name
    action=continue
    while getopts ":i:mru" opt; do
      case $opt in
        i) startIntegrationIndex=$OPTARG
          ;;
        m) ignoreMd5InState=yes
          ;;
        r) restart=yes
          ;;
        u) safe=
          ;;

        \?)
          echo "Error: Unexpected argument: -$OPTARG"
          echo
          usage
          exit 1
      esac
    done
  else
    echo "Error: Unsupported action: $action"
    echo
    usage
    exit 1
  fi
}

function trim() {
  echo "$1" | sed -e 's/^\s*//; s/\s*$//'
}


#
# === Execution ===
#

processArguments "$@"

scratch=$( mktemp -d -t "$namePrefix.tmp.XXXXXXXXXX" )
function cleanup {
  [[ -e $scratch ]] && rm -rf "$scratch"
}
trap cleanup EXIT

# First integration to start with.
integrationToStart=0
# Current integration index.  Used to continue after an error or a pause.
integrationIndex=0
# First operation to perform on integration $integrationToStart.
# Operations are:
#   start - Synonym for the next operation name.  For convenience in case actual
#           first operation name changes.
#   check - Checks if we should skip this branch.
#   description - Generates merge description.
#   update - Update client spec.
#   sync - p4 sync.
#   changelist - Create a new changelist.
#   integrate - p4 integrate.
#   resolve - p4 resolve.
#   submit - p4 submit.
operation=start
# Changelist to use.  Makes sense for actions changelist and on.
newCL=0

# Used to match state file to the configuration file.
# Will will populate it later, after we figure out our configuration file name.
configFileMd5=

# MD5 read from the state file, if any.
expectedConfigFileMd5=

# Config parser will set the following variables:
#
# enableInView_count - number of enableInView patterns.
# enableInView_[0-9]* - literal sed regex that will distinguish view mappings
#   enabled in the client view.  Any mapping not matching an "enableInView_*"
#   pattern is disabled.
#
# client - current master client to use.
# shortTitle - short description of the current integration.
# check_count - number of checks that need to be performed for this integration.
#   check_[0-9]*_op - this check operation, either "integrated" or "skip"
#
#     For "integrated" operation sets:
#
#       check_[0-9]*_from - source location for the check.
#       check_[0-9]*_to - target location for the check.
#
#     This check is expected to make sure "from" is completely integrated into
#     "to".
#
#     For "skip" operation sets:
#
#       check_[0-9]*_message - skip reason.
#
#     This check will unconditionally skip the integration, providing the
#     message as an example.

function loadState() {
  # Status file may contain comments and empty lines.  For the header part we do
  # not care about them.
  exec 3< <( sed -e 's/^\s*#.*//; /^$/d' "$stateFileName" )
  read -u 3 -r expectedConfigFileName || {
    echo "Error: Failed to read config file name from: $stateFileName"
    exit 2
  }
  read -u 3 -r integrationToStart operation newCL expectedConfigFileMd5 || {
    echo "Error: Failed to read state from: $stateFileName"
    exit 2
  }
  exec 3<&-

  [[ -r "$expectedConfigFileName" ]] || {
    echo "Error: Can not read expected config file: $expectedConfigFileName"
    exit 2
  }
  configFileName=$expectedConfigFileName
}

function checkIfConfigIsReadable() {
  [[ -r $configFileName ]] || {
    echo "Error: Can not read config file: $configFileName"
    exit 2
  }
}

function calculateConfigMd5 () {
  configFileMd5=$( md5sum "$configFileName" | awk '{print $1}' )
}

function checkConfigMd5() {
  if [[ $ignoreMd5InState != yes && $expectedConfigFileMd5 != 0 ]]; then
    if [[ $configFileMd5 != $expectedConfigFileMd5 ]]; then
      echo "Error: Current configuration file MD5 ($configFileMd5) is different"
      echo "       from the stored configuration file MD5" \
           "($expectedConfigFileMd5)."
      echo
      echo "It may indicate that your configuration file was modified since"
      echo "the state was stored.  You may restart from the very beginning:"
      echo
      echo "    $( basename $0 ) go -r"
      echo
      echo "Or ignore the MD5 check if you are sure that you did not introduce"
      echo "any breaking changes:"
      echo
      echo "    $( basename $0 ) continue -m"
      echo
      exit 2
    fi
  fi
}

function adjustStartIntegrationAndOperation() {
  if [[ $startIntegrationIndex != '' ]]; then
    restartIntegration
    integrationToStart=$startIntegrationIndex
  elif [[ $restart != '' ]]; then
    restartIntegration
  fi
}

function restartIntegration() {
  if [[ $newCL == 0 ]]; then
    return
  fi

  if ! p4 opened -c "$newCL" -s \
      >"$scratch/opened.list" 2>"$scratch>opened.err" ; then
    cat <<EOF
Error: Failed to get a list of files opened in changelist: $newCL
Command: p4 opened -c "$newCL" -s
Output:
EOF
    cat "$scratch/opened.list" | sed -e 's/^/  /'
    echo "Error output:"
    cat "$scratch/opened.err" | sed -e 's/^/  /'
    exit 1
  fi

  if [[ -s "$scratch/opened.err" && \
      ! "$(< "$scratch/opened.err" )" =~ 'File(s) not opened anywhere.' ]]; then
    cat <<EOF
Error: p4 opened showed unexpected error
Command: p4 opened -c "$newCL" -s
Output:
EOF
    cat "$scratch/opened.list" | sed -e 's/^/  /'
    echo "Error output:"
    cat "$scratch/opened.err" | sed -e 's/^/  /'
    exit 1
  fi

  if [[ -s "$scratch/opened.list" ]] \
    && ! cat "$scratch/opened.list" | \
    # XXX This is ugly :(  Is there a better way?
    sed -e 's/ - \w\+ change [0-9]\+ by [^ @]\+@[^ ]\+$//' | \
    xargs -a - -d '\n' p4 revert -w -c "$newCL" 2>"$scratch/revert.err" ; then
    cat <<EOF
Error: Failed to revert pending changelist: $newCL

You may try to revert all the files in this changelist manually and retry.

EOF
    cat "$scratch/revert.err" | sed -e 's/^/  /'
    exit 1
  fi

  if ! p4 change -d "$newCL" 2>"$scratch/change.err" ; then
    cat <<EOF
Error: Failed to delete pending changelist: $newCL

You may try to delete it manually and retry.

EOF
    cat "$scratch/revert.err" | sed -e 's/^/  /'
    exit 1
  fi

  newCL=0
  operation=start
}

function saveState() {
  # We need to regenerate the description if we did not reach the changelist
  # creation.  TODO It would be better to store generated description in the
  # state file instead.
  if [[ $operation = check || $operation = update || $operation = sync \
      || $operation = changelist ]]; then
    operation=description
  fi
  echo '# configFileName' >"$stateFileName".new
  echo "$configFileName" >>"$stateFileName".new
  echo '# integration operation changelist configFileMD5' >>"$stateFileName".new
  echo "$integrationIndex $operation $newCL $configFileMd5" >>"$stateFileName".new
  echo >>"$stateFileName".new
  echo Report: >>"$stateFileName".new
  sed -e '1,/^Report:/d' "$stateFileName" >> "$stateFileName".new
  mv "$stateFileName".new "$stateFileName"
}

# Arguments:
#   1 - Error title.
#   2 - Error message to output just after the title line.  Not output if empty.
#   3 - File name whos content is output just after the title line.  Not output
#       if empty.
function saveStateAndExit() {
  echo "Error: $1"

  if [[ $2 != "" ]]; then
    echo "$2" | sed -e 's/^/  /'
  fi

  if [ "$3" != "" -a -s "$3" ]; then
    echo
    cat "$3" | sed -e 's/^/  /'
  fi

  cat <<EOF

Fix it and run

    $( basename $0 ) continue

to continue the process.

Current integation index (for -i):  $integrationIndex
EOF
  saveState
  exit 1
}


#
# === Operations the scrpt can do ===
#

function operation_check() {
  local op
  for (( i = 0 ; i < check_count ; ++i )); do
    eval "op=\$check_${i}_op"
    case $op in
      integrated)
        operation_check_integrated "$i"
        ;;

      skip)
        operation_check_skip "$i"
        ;;

      *)
        saveStateAndExit "Internal: unexpected check operation: $op"
    esac
  done
}

function operation_check_integrated() {
  local i="$1" from to output
  eval "from=\$check_${i}_from"
  eval "to=\$check_${i}_to"

  cat <<EOF | p4 client -i || saveStateAndExit "p4 client failed"
$( p4 client -o | sed -ne '1,/^View:/p' )
	$to //$( p4 client -o | sed -ne '/^Client:/ { s@^[^:]*:\s*@@; P }' )/...
EOF

  output=$( p4 integrate -v -n -m 1 "$from" "$to" 2>"$scratch/int.err" )

  echo "Debug:2: $output"
  echo "Debug:3: $(< "$scratch/int.err" )"

  if [[ -s "$scratch/int.err" ]]; then
    if [[ "$(< "$scratch/int.err" )" =~ \
          'all revision(s) already integrated.' ]]; then
      return
    else
      saveStateAndExit "Unexpected output from p4 integrate." \
        "" "$scratch/ic.err"
    fi
  elif [[ $output =~ ' from //' ]]; then
    echo " - Skipping.  Unintegrated changes: $from => $to"

    operation=end

    echo "Skipped: $shortTitle" >>"$stateFileName"
    echo "    Unintegrated: $from => $to" >>"$stateFileName"
  else
      saveStateAndExit "Unexpected output from p4 integrate" "$output"
  fi

  saveStateAndExit "Debug"
}

function operation_check_skip() {
  local i="$1" message
  eval "message=\$check_${i}_message"

  echo " - Skipping.  Reason: $message"

  operation=end

  echo "Skipped: $shortTitle" >>"$stateFileName"
  echo "    Reason: $message" >>"$stateFileName"
}

function operation_description() {
  # The awk script is supposed to "unindent" and "undecorate" our own chunks
  # in the description that has "Latest changes: ..." in it.  We would add
  # those later again and if not done when changes are integrated across
  # branches we would accumulate that extra decoration along with extra
  # indentation.
  # XXX When change description contains our default template, a server script
  # will automatically insert "Jobs:" marker after it creating invalid change
  # list.  So we remove the "<enter description here>" line that is followed by
  # an optional whitespace line and a line with the "RQ:" tag.

  changeDescription=$(
    p4 interchanges -l "$fromBranch" "$toBranch" 2>"$scratch/ic.err" | \
      sed -e '
        /^\s*<\?enter description here>\?\s*$/{
          # Take the next line.
          N
          # Add one more line if we appended an all whitespace line.
          /\n\s*$/{ s/\n\s*//; N }
          # Remove both lines if the second one is that RQ: line.
          /\n\s*RQ:\s*$/d
        }' | \
      awk -v RS="(^|\n)Change" -v ORS="" '
        /\n	Latest changes:/ {
          # Unindent one level
          gsub(/\n	/, "\n")
          # Remove our header
          sub(/^ [0-9]+ on [^\n]*\
(\s*\n)*\
Latest changes:[^\n]*\
(\s*\n)*\
\$ p4 interchanges [^\n]*(\s*\n)*/, "")
          # Remove our footer along with any extra whitespace at the end.
          sub(/(\s*\n)*\
\$ p4 integrate[^\n]*\
(\s*\n)*$/, "")
          print $0 "\n\n"
          next
        }
        $0 ~ /./ { print "Change" $0 "\n" }
      ' | sed -e 's/^/	/'
  )

  if [[ -s "$scratch/ic.err" ]]; then
    if [[ "$(< "$scratch/ic.err" )" =~ \
          'all revision(s) already integrated.' ]]; then
      echo ' - Nothing to integrate skipping'

      operation=end

      echo "No changes: $shortTitle" >>"$stateFileName"
    elif [[ "$(< "$scratch/ic.err" )" =~ 'Too many rows scanned' ]]; then
      changeDescription="	Failed to generate details description.\n
	'maxscanrows' limit reached.\n"
    else
      saveStateAndExit "Unexpected output from p4 interchanges." \
        "" "$scratch/ic.err"
    fi
  fi
}

function operation_update() {
  local viewTransform pattern

  for (( i = 0 ; i < enableInViews_count ; ++i )); do
    eval "pattern=\$enableInViews_${i}"
    viewTransform="$viewTransform\
      "'\#^\t\(.*'"$pattern"'.*\)# { s/^\t-/\t/; b view }'$'\n' 
  done

  cat <<EOF | p4 client -i || saveStateAndExit "p4 client failed"
$( p4 client -o | grep '^\(Options\|SubmitOptions\):' )
$( p4 client -o -t "$client" | grep -v '^\(Options\|SubmitOptions\):' | \
    sed -e '
    /^View:\s*$/ {
:view
      n

'"$viewTransform"'

      /^\t/ {
        s/^\t-\?/\t-/
        b view
      }
    }
  ')
EOF
}

function operation_sync() {
  p4 sync -q || saveStateAndExit "p4 sync failed"
}

function operation_changelist() {
  newCL=$( cat <<EOF | tee debug.log | p4 change -i | cut -d ' ' -f 2
Change: new
$( p4 change -o | grep '^Client:\|^User:' )

Description:
	Latest changes: $shortTitle
	
	\$ p4 interchanges -l $fromBranch $toBranch
	
$changeDescription
	\$ p4 integrate $fromBranch $toBranch
EOF
  )
  if [ "$?" -ne 0 ]; then
    newCL=0
    saveStateAndExit "Failed to create new changelist"
  fi
}

function operation_integrate() {
  p4 integrate -c "$newCL" "$fromBranch" "$toBranch" 2>"$scratch/int.err" || \
    saveStateAndExit "p4 integrate failed" "" "$scratch/int.err"
  [[ -s $scratch/int.err ]] && \
    saveStateAndExit "p4 integrate failed" "" "$scratch/int.err"
}

function operation_resolve() {
  p4 resolve -c "$newCL" -as || saveStateAndExit "p4 resolve failed"

  if [ "$safe" != "" ]; then
    operation=submit
    echo " # Check resolution and message"
    saveState
    exit 0
  fi
}

function operation_submit() {
  p4 submit -c "$newCL" 2>"$scratch/submit.err" || \
    saveStateAndExit "p4 submit failed" "" "$scratch/submit.err"

  echo "Latest changes: $shortTitle" >>"$stateFileName"
}

# === End of operations ===

if [[ $action = go ]]; then
  checkIfConfigIsReadable
  calculateConfigMd5

  if [[ -r $stateFileName && ! $restart == yes ]]; then
    echo "Error: State file is present."
    echo
    echo "You might be in a middle of the merge process."
    echo "To continue the merge process run"
    echo
    echo "    $( basename $0 ) continue"
    echo
    echo "Or to restart the process run"
    echo
    echo "    $( basename $0 ) go -r"
    echo
    exit 1
  fi

  echo '# integration operation changelist configFileMD5' >"$stateFileName"
  echo '0 start 0 0' >>"$stateFileName"
  echo >>"$stateFileName"
  echo Report: >>"$stateFileName"
elif [[ $action = continue ]]; then
  [[ -r $stateFileName ]] || {
    echo "Error: Can not read state file: $stateFileName"
    exit 2
  }

  loadState
  checkIfConfigIsReadable
  calculateConfigMd5
  checkConfigMd5
  adjustStartIntegrationAndOperation
fi

function configError() {
  saveStateAndExit "$configFileName:$1: $2"
}

# Configuration parser is written in sed.  It ouputs "cooked" variable
# assignments that bash just needs to eval.  Special token '==go==' means
# configuration for the next integration is done.
# 'configError <line number> <error message>' is returned in case of an error in
# the configuration file.
# 'nl' prefixes all the lines with their numbers - line numbers are used when
# reporting errors.
exec 3< <( nl -s: -w1 -nln -hn -fn -ba "$configFileName" | \
  sed -ne '
  h
  s@^[0-9]\+:@@

  s@^\s\+@@
  s@\s\+$@@

  /^$/d
  /^#/d

  /^\s*%\s*options\s*%\s*$/ {
    s@.*@\
      enableInViews_count=0@
    p

:options

    n;h;s@^[0-9]\+:@@

    /^\s*enable-in-views\s*:/ {
      s@^\s*enable-in-views\s*:\s*@@
      s@\s\+$@@
      s@^\(.*\)$@\
        eval "enableInViews_${enableInViews_count}=\\"\1\\""\
        enableInViews_count=$(( enableInViews_count + 1))@
      p
      b options
    }
  }

  /^\s*\S\+\s*:/ {

    s@^\s\+@@
    s@\s\+$@@

    s@^\(\S\+\)\s*:\s*\(.*\)$@\
      client="\1"\
      shortTitle="\2"\
      check_count=0@
    p
    n;h;s@^[0-9]\+:@@

:checks

    s@^\s\+@@
    s@\s\+$@@

    /^#/ {
      n;h;s@^[0-9]\+:@@
      b checks
    }
    /^$/ {
      n;h;s@^[0-9]\+:@@
      b checks
    }

    /^only-when-integrated\s*:/ {
      s@^only-when-integrated\s*:\s*@@
      s@\s*=>\s*@=>@
      /=>.*=>/ {
        g
        s@^\([0-9]\+\):.*$@configError "\1" "Contains two \\"=>\\""@
        p
        q
      }
      s@^\(.*\)=>\(.*\)$@\
        eval "check_${check_count}_op=integrated"\
        eval "check_${check_count}_from=\\"\1\\""\
        eval "check_${check_count}_to=\\"\2\\""\
        check_count=$(( check_count + 1 ))@
      p
      n;h;s@^[0-9]\+:@@
      b checks
    }

    /^skip\s*:/ {
      s@^\s*skip\s*:\s*@@
      s@^\(.*\)$@\
        eval "check_${check_count}_op=skip"\
        eval "check_${check_count}_message=\\"\1\\""\
        check_count=$(( check_count + 1 ))@
      p
      n;h;s@^[0-9]\+:@@
      b checks
    }

    /^[^:]\+=>/ {
      s@\s*=>\s*@=>@
      /=>.*=>/ {
        g
        s@^\([0-9]\+\).*$@configError "\1" "Contains two \\"=>\\""@
        p
        q
      }
      s@^\(.*\)=>\(.*\)$@\
        fromBranch="\1"\
        toBranch="\2"\
        ==go==@
      p
      b
    }

    g
    s@^\([0-9]\+\):.*$@configError "\1" "Can not parse"@
    p
    q
  }
' )

while read -u 3 -r configLine; do
  if [[ $configLine != "==go==" ]]; then
    eval "$configLine"
    continue
  fi

  integrationIndex=$(( integrationIndex + 1 ))

  [[ $integrationIndex -lt $integrationToStart ]] && {
    echo "Already processed $shortTitle"
    continue
  }

  echo "Merging $fromBranch => $toBranch"

  [[ $operation = start ]] && operation=description

  if [[ $operation = description ]]; then
    echo " = Generating change description ..."
    operation_description
    [[ $operation = description ]] && operation=check
  fi

  if [[ $operation = check ]]; then
    echo " = Checking integration prerequisites..."
    operation_check
    [[ $operation = check ]] && operation=update
  fi

  if [[ $operation = update ]]; then
    echo " = Updating client spec ..."
    operation_update
    [[ $operation = update ]] && operation=sync
  fi

  if [[ $operation = sync ]]; then
    echo " = Syncing ..."
    operation_sync
    [[ $operation = sync ]] && operation=changelist
  fi

  if [[ $operation = changelist ]]; then
    echo " = Creating a changelist ..."
    operation_changelist
    [[ $operation = changelist ]] && operation=integrate
  fi

  if [[ $operation = integrate ]]; then
    echo " = Integration ..."
    operation_integrate
    [[ $operation = integrate ]] && operation=resolve
  fi

  if [[ $operation = resolve ]]; then
    echo " = Conflict resolution ..."
    operation_resolve
    [[ $operation = resolve ]] && operation=submit
  fi

  if [[ $operation = submit ]]; then
    echo " = Submitting ..."
    operation_submit
    [[ $operation = submit ]] && operation=end
  fi

  [[ $operation != end ]] && \
    saveStateAndExit "Internal: \$operation is \"$operation\" and not \"end\""

  # Next branch starts from the very first operation and with no changelist.
  operation=start
  newCL=0
done

echo "All done"
echo
echo "Here is what happened:"
sed -e '1,/^Report:/d; s/^/  /' "$stateFileName"

rm "$stateFileName"

# vim: sw=2 sts=2 ts=2 et tw=80
