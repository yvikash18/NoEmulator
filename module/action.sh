#!/system/bin/sh
# The Action button on the module card in the KernelSU manager: write a log
# report for a bug report. The manager shows this script's output.

MODDIR=${0%/*}

echo "Collecting NoEmulator logs..."
if report=$(sh "$MODDIR/lib/collect_logs.sh"); then
    echo "Saved: $report"
    echo "Attach it to an issue at https://github.com/ymuuuu/NoEmulator/issues"
else
    echo "Could not write the report."
    exit 1
fi
