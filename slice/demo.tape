# vhs tape: the promotion-freeze refusal, recorded live against the e2e
# cluster at the moment the budget is exhausted (hack/e2e-kind.sh runs this
# between Phase C and Phase D when RECORD_GIF=1).
Output slice/demo.gif
Set FontSize 14
Set Width 1180
Set Height 620
Set TypingSpeed 35ms
Set Padding 12

Type "# the error budget is exhausted — the operator froze promotions"
Enter
Sleep 500ms
Type "kubectl -n agents get agents"
Enter
Sleep 2.5s

Type "# a feature PromptVersion is refused: no canary, no gate, phase Frozen"
Enter
Sleep 500ms
Type "kubectl -n agents get promptversions"
Enter
Sleep 2.5s

Type "kubectl -n agents get promptversion support-v2 -o jsonpath='{.status.message}'"
Enter
Sleep 4s
Enter

Type "# an SLO-restoring fix is exempt: it passes the FREEZE, never the GATE"
Enter
Sleep 500ms
Type "kubectl -n agents apply -f slice/manifests/promptversion-hotfix.yaml"
Enter
Sleep 8s

Type "kubectl -n agents get promptversions"
Enter
Sleep 4s
