# email_flowmon-pl
Monitor email flow, end-to-end.

## Summary
A program to test email flow from origin to destination.

## Description
This program sends an email to a specified address via sendmail and
then monitors an IMAP folder for that email to arrive. If the email
arrives within the time constraint, it is deleted and this program
is silent. If not, this program complains.

The program operates via a config file that is a simple Perl hash.
An example config should accompany the program.

The original motivation for this program was a glitch at my email
provider that led to emails not being forwarded and it took a few
days for me to notice. Now I use this program to monitor that email
flow end-to-end.

## Example usage
```bash
hightowe@eden ~/bin $ ./email_flowmon.pl --verbose
Test email sent: email_flowmon.pl test email 44559981144e2438b
IMAP search found: 0
IMAP search found: 0
IMAP search found: 1
Test was successful in 15 seconds.
```

## Author and Platform
Originally written September 24, 2024, by Lester Hightower and
on Linux Mint 21. It should work on most Unix flavors.

