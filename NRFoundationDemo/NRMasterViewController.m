//
//  NRMasterViewController.m
//  NRFoundationDemo
//
//  Created by Nikolai Ruhe on 2012-08-27.
//  Copyright (c) 2012 Nikolai Ruhe. All rights reserved.
//

#import "NRMasterViewController.h"
#import "NRDetailViewController.h"
#import "NRFoundation.h"


@implementation NRMasterViewController

@synthesize controlSlider = _controlSlider;

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.controlSlider nr_addBlockAction:^(id sender) {
		UISlider *slider = sender;
		slider.thumbTintColor = [UIColor colorWithHue:((UISlider *)sender).value saturation:1 brightness:1 alpha:1];
	} forControlEvents:UIControlEventValueChanged];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
	return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

- (void)presentUIActionSheet
{
	[[[UIActionSheet alloc] nr_initWithTitle:@"NRFoundation"
						   cancelButtonTitle:@"Great"
									  action:^(UIActionSheet *actionSheet, NSUInteger buttonIndex) {
										  [self logMessage:@"--- Great ---"];
									  }
					  destructiveButtonTitle:@"Perfect"
									  action:^(UIActionSheet *actionSheet, NSUInteger buttonIndex) {
										  [self logMessage:@"--- Perfect ---"];
									  }
							otherButtonTitle:@"OK"
									  action:^(UIActionSheet *actionSheet, NSUInteger buttonIndex) {
										  [self logMessage:@"--- Accepted ---"];
									  }] showInView:self.view];
}

- (void)logMessage:(NSString *)message
{
	CGFloat ypos = 458;
	UILabel *label = [[UILabel alloc] initWithFrame:(CGRect){.size={320, 44}}];
	label.center = (CGPoint){480, ypos};
	label.text = message;
	label.textAlignment = UITextAlignmentCenter;
	label.font = [UIFont boldSystemFontOfSize:22];
	label.alpha = 0;
	[[[[UIApplication sharedApplication] delegate] window] addSubview:label];
	[UIView animateWithDuration:.75 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
		label.center = (CGPoint){160, ypos};
		label.alpha = 1;
	} completion:^(BOOL finished) {
		[UIView animateWithDuration:.25 delay:1.5 options:UIViewAnimationOptionCurveEaseIn animations:^{
			label.center = (CGPoint){-160, ypos};
			label.alpha = 0;
		} completion:^(BOOL finished) {
			[label removeFromSuperview];
		}];
	}];
}

- (void)presentUIAlertView
{
	[[[UIAlertView alloc] nr_initWithTitle:@"NRFoundation"
								   message:@"This alert view needs less boilerplate code."
						 cancelButtonTitle:@"Great"
									action:^(UIAlertView *alertView, NSUInteger buttonIndex) {
										[self logMessage:@"--- Great ---"];
									} otherButtonTitle:@"OK"
									action:^(UIAlertView *alertView, NSUInteger buttonIndex) {
										[self logMessage:@"--- Accepted ---"];
									}] show];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSString *title = [[tableView cellForRowAtIndexPath:indexPath] textLabel].text;
	SEL selector = NSSelectorFromString([NSString stringWithFormat:@"present%@", title]);
	if ([self respondsToSelector:selector]) {
		[tableView deselectRowAtIndexPath:indexPath	animated:YES];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
		[self performSelector:selector];
#pragma clang diagnostic pop
	}
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([[segue identifier] isEqualToString:@"showDetail"]) {
        NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
		UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
		((NRDetailViewController *)[segue destinationViewController]).title = cell.textLabel.text;
    }
}

@end
