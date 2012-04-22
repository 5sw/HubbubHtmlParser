//
//  HtmlParser.h
//  HtmlParser
//
//  Created by Sven Weidauer on 08.04.12.
//  Copyright (c) 2012 Sven Weidauer. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface HubbubHtmlParser : NSObject

+ (NSXMLDocument *)parseDocument: (NSData *)data;

@end
