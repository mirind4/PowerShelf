
<#
.Synopsis
	Adds a script debugger to PowerShell.
	Author: Roman Kuzmin

.Description
	This script is designed for PowerShell runspaces which do not have their
	own debuggers, e.g. Visual Studio NuGet console ("Package Manager Host"),
	the default runspace host ("Default Host"), and etc. It should be called
	from such a runspace once at any moment when debugging is needed.

	The GUI input box is used for typing of PowerShell and debugger commands.
	For output of these commands the script uses Write-Host or a file with a
	separate console started for watching the output.

.Parameter Path
		Specifies the output file used instead of Write-Host.
		A separate console is opened for watching the output.

.Inputs
	None
.Outputs
	None

.Example
	>
	How to debug terminating errors in a bare runspace. Use cases:
	- In .NET the similar code is typical for invoking PowerShell.
	- In PowerShell InvokeAsync() makes sense for background jobs.

	$ps = [PowerShell]::Create()
	$null = $ps.AddScript({
		# add debugger with file output
		Add-Debugger.ps1 $env:TEMP\debug.log

		# enable debugging on terminating errors
		$null = Set-PSBreakpoint -Variable StackTrace -Mode Write

		# from now on the debugger dialog is shown on failures
		# and a separate PowerShell output console is started
		...
	})
	$ps.Invoke() # or InvokeAsync()

.Link
	https://github.com/nightroman/PowerShelf
#>

param(
	[Parameter()]
	[string]$Path
)

# Add the stop handler and data once
if (!(Test-Path Variable:\__Debugger)) {
	[System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.Debugger.add_DebuggerStop({ . Invoke-DebuggerStop })
	Add-Type -AssemblyName Microsoft.VisualBasic

	# Debugger data. MaximumHistoryCount and DebugContext can be customized.
	$null = New-Variable -Name __Debugger -Scope Global -Description 'Debugger data.' -Option Constant -Value @{
		MaximumHistoryCount = 50
		DebugContext = 0
		Context = [ref]0
		History = @()
		Action = '?'
	}
}

# Writes the debugger output.
if ($Path) {
	$__Debugger.Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
	$__Debugger.Watch = $true
	function global:Write-Debugger($Object)
	{
		$Object >> $__Debugger.Path
		if ($__Debugger.Watch) {
			$__Debugger.Watch = $false
			Watch-Debugger $__Debugger.Path
		}
	}
}
else {
	$__Debugger.Path = $null
	$__Debugger.Watch = $false
	function global:Write-Debugger($Object)
	{
		Write-Host $Object
	}
}

# Starts an external viewer to watch output.
function global:Watch-Debugger($Path)
{
	Start-Process PowerShell.exe -ArgumentList "-NoProfile Get-Content '$Path' -Wait"
}

# Writes the current invocation info.
function global:Write-DebuggerInfo(
	[Parameter()]
	$InvocationInfo,
	[int]$Context = 5
)
{
	# write position message
	Write-Debugger $InvocationInfo.PositionMessage.Trim()

	# done?
	$file = $InvocationInfo.ScriptName
	if ($Context -le 0 -or !$file -or !(Test-Path -LiteralPath $file)) {return}

	# write file content
	$markIndex = $InvocationInfo.ScriptLineNumber - 1
	Write-DebuggerFile $file ($markIndex - $Context) (2 * $Context + 1) $markIndex
}

# Writes the specified script content.
function global:Write-DebuggerFile(
	[Parameter()]
	[string]$Path,
	[int]$LineIndex,
	[int]$LineCount,
	[int]$MarkIndex
)
{
	# correct negative start
	if ($LineIndex -lt 0) {
		$LineCount += $lineIndex
		$LineIndex = 0
	}

	# content lines
	$lines = @(Get-Content -LiteralPath $Path -TotalCount ($LineIndex + $LineCount) -ErrorAction 0 -Force)

	# leading spaces
	$space = ($lines[$LineIndex .. -1] | .{process{
		if ($_ -match '^(\s*)\S') {
			($matches[1] -replace "`t", '    ').Length
		}
	}} | Measure-Object -Minimum).Minimum

	# write lines with a mark
	Write-Debugger ''
	do {
		if (($line = $lines[$LineIndex]) -match '^(\s*)(\S.*)') {
			$line = ($matches[1] -replace "`t", '    ').Substring($space) + $matches[2]
		}
		$mark = if ($LineIndex -eq $MarkIndex) {'=>'} else {'  '}
		Write-Debugger ('{0,4} {1} {2}' -f ($LineIndex + 1), $mark, $line)
	}
	while(++$LineIndex -lt $lines.Length)
	Write-Debugger ''
}

# Processes DebuggerStop events.
function global:Invoke-DebuggerStop
{
	# write breakpoints
	if ($_.Breakpoints) {&{
		Write-Debugger ''
		foreach($b in $_.Breakpoints) {
			if ($b -is [System.Management.Automation.VariableBreakpoint] -and $b.Variable -eq 'StackTrace') {
				Write-Debugger 'TERMINATING ERROR BREAKPOINT'
			}
			else {
				Write-Debugger "Hit $b"
			}
		}
	}}

	# write debug location
	Write-DebuggerInfo $_.InvocationInfo $__Debugger.DebugContext
	Write-Debugger ''

	# REPL
	$__Debugger.e = $_
	for() {
		### prompt
		$__Debugger.Action = [Microsoft.VisualBasic.Interaction]::InputBox(
			"Enter PowerShell and debug commands.`nUse h or ? for help.",
			'Debugger',
			$__Debugger.Action
		).Trim()

		### echo
		Write-Debugger "DBG> $($__Debugger.Action)"

		### continue
		if (!$__Debugger.Action -or $__Debugger.Action -eq 'c' -or $__Debugger.Action -eq 'Continue') {
			$__Debugger.e.ResumeAction = 'Continue'
			return
		}

		### StepInto
		if ($__Debugger.Action -eq 's' -or $__Debugger.Action -eq 'StepInto') {
			$__Debugger.e.ResumeAction = 'StepInto'
			return
		}

		### StepOver
		if ($__Debugger.Action -eq 'v' -or $__Debugger.Action -eq 'StepOver') {
			$__Debugger.e.ResumeAction = 'StepOver'
			return
		}

		### StepOut
		if ($__Debugger.Action -eq 'o' -or $__Debugger.Action -eq 'StepOut') {
			$__Debugger.e.ResumeAction = 'StepOut'
			return
		}

		### Quit
		if ($__Debugger.Action -eq 'q' -or $__Debugger.Action -eq 'Quit') {
			$__Debugger.e.ResumeAction = 'Stop'
			return
		}

		### history
		if ($__Debugger.Action -eq 'r') {
			Write-Debugger ($__Debugger.History | Out-String)
			continue
		}

		### stack
		if ($__Debugger.Action -ceq 'k') {
			Write-Debugger (Get-PSCallStack | Format-Table Command, Location, Arguments -AutoSize | Out-String)
			continue
		}
		if ($__Debugger.Action -ceq 'K') {
			Write-Debugger (Get-PSCallStack | Format-List | Out-String)
			continue
		}

		### <number>
		if ([int]::TryParse($__Debugger.Action, $__Debugger.Context)) {
			Write-DebuggerInfo $__Debugger.e.InvocationInfo $__Debugger.Context.Value
			if ($__Debugger.Action[0] -eq "+") {
				$__Debugger.DebugContext = $__Debugger.Context.Value
			}
			continue
		}

		### help
		if ($__Debugger.Action -eq '?' -or $__Debugger.Action -eq 'h') {
			Write-Debugger @'

  s, StepInto  Step to the next statement into functions, scripts, etc.
  v, StepOver  Step to the next statement over functions, scripts, etc.
  o, StepOut   Step out of the current function, script, etc.
  c, Continue  Continue operation (also on Cancel or empty).
  q, Quit      Stop operation and exit the debugger.
  ?, h         Write this help message.
  k            Write call stack (Get-PSCallStack).
  K            Write detailed call stack using Format-List.

  <n>          Write debug location in context of <n> lines.
  +<n>         Set location context preference to <n> lines.
  k <s> <n>    Write source at stack <s> in context of <n> lines.

  w            Restart watching the debugger output file.
  r            Write last PowerShell commands invoked on debugging.
  <command>    Invoke any PowerShell <command> and write its output.

'@
			continue
		}

		### stack <s> <n>
		function k([Parameter()][int]$s, [int]$n) {
			$stack = @(Get-PSCallStack)
			if ($s -ge $stack.Count) {
				Write-Debugger 'Out of range of the call stack.'
				return
			}
			$1 = $stack[$s]
			if (!($file = $1.ScriptName)) {
				Write-Debugger 'The caller has no script file.'
				return
			}
			if ($n -le 0) {$n = 5}
			$markIndex = $1.ScriptLineNumber - 1
			Write-Debugger $file
			Write-DebuggerFile $file ($markIndex - $n) (2 * $n + 1) $markIndex
		}

		### watch
		function w {
			if ($__Debugger.Path) {
				Watch-Debugger $__Debugger.Path
			}
		}

		### invoke command
		try {
			Write-Debugger (.([scriptblock]::Create($__Debugger.Action)) | Out-String)
			$__Debugger.History = $__Debugger.History |
			.{process{ if ($_ -ne $__Debugger.Action) {$_} } end { $__Debugger.Action }} |
			Select-Object -Last $__Debugger.MaximumHistoryCount
		}
		catch {
			Write-Debugger $(if ($_.InvocationInfo.ScriptName -like '*\Add-Debugger.ps1') {$_.ToString()} else {$_})
		}
	}
}