# Tier C gate enforcement policy.
#
# These are deliberately single-point, reversible switches. Operators may
# override either value in the process environment for a controlled rollback.
# 1 = block the transition on a failed check; 0 = do not block.
: "${FATQ_G09_BLOCKING:=0}"
: "${FATQ_G12_BLOCKING:=0}"
