//
//  HtmlParser.m
//  HtmlParser
//
//  Created by Sven Weidauer on 08.04.12.
//  Copyright (c) 2012 Sven Weidauer. All rights reserved.
//

#import "HubbubHtmlParser.h"

#include <hubbub/hubbub.h>
#include <hubbub/tree.h>
#include <hubbub/parser.h>



@interface HubbubHtmlParser () {
	hubbub_parser *_parser;
	hubbub_error _lastError;
	struct hubbub_tree_handler _treeHandler;
	hubbub_quirks_mode _quirksMode;
}

@property (strong) NSXMLDocument *document;
@property (strong) NSMutableArray *nodes;
@property (copy) NSString *charset;

@end


@implementation HubbubHtmlParser

@synthesize document = _document;
@synthesize nodes = _nodes;
@synthesize charset = _charset;

static hubbub_error create_comment( void *ctx, const hubbub_string *data, void **result );
static hubbub_error create_doctype( void *ctx, const hubbub_doctype *doctype, void **result );
static hubbub_error create_element( void *ctx, const hubbub_tag *tag, void **result );
static hubbub_error create_text( void *ctx, const hubbub_string *data, void **result );
static hubbub_error ref_node( void *ctx, void *node );
static hubbub_error unref_node( void *ctx, void *node );
static hubbub_error append_child( void *ctx, void *parent, void *child, void **result );
static hubbub_error insert_before( void *ctx, void *parent, void *child, void *ref_child, void **result );
static hubbub_error remove_child( void *ctx, void *parent, void *child, void **result );
static hubbub_error clone_node( void *ctx, void *node, bool deep, void **result );
static hubbub_error reparent_children( void *ctx, void *node, void *new_parent );
static hubbub_error get_parent( void *ctx, void *node, bool element_only, void **result );
static hubbub_error has_children( void *ctx, void *node, bool *result );
static hubbub_error form_associate( void *ctx, void *form, void *node );
static hubbub_error add_attributes( void *ctx, void *node, const hubbub_attribute *attributes, uint32_t n_attributes );
static hubbub_error set_quirks_mode( void *ctx, hubbub_quirks_mode mode );
static hubbub_error change_encoding( void *ctx, const char *charset );
static void *mem_realloc(void *ptr, size_t len, void *pw);


static struct hubbub_tree_handler tree_handler = { 	
	create_comment,
	create_doctype,
	create_element,
	create_text,
	ref_node,
	unref_node,
	append_child,
	insert_before,
	remove_child,
	clone_node,
	reparent_children,
	get_parent,
	has_children,
	form_associate,
	add_attributes,
	set_quirks_mode,
	change_encoding,
	NULL
};

- (id)initWithCharset: (NSString *)charset;
{
	self = [super init];
	if (!self) return nil;

	_charset = [charset copy];

	hubbub_error error = hubbub_parser_create( [_charset UTF8String], true, mem_realloc, (__bridge void *)self, &_parser );
	if (error != HUBBUB_OK) {
		return nil;
	}
	
	_document = [NSXMLDocument document];
	_document.documentContentKind = NSXMLDocumentHTMLKind;
	
	_treeHandler = tree_handler;
	_treeHandler.ctx = (__bridge void *)self;
	
	hubbub_parser_optparams params;
	
	params.tree_handler = &_treeHandler;
	hubbub_parser_setopt( _parser, HUBBUB_PARSER_TREE_HANDLER, &params );

	params.document_node = (__bridge void *)_document;
	hubbub_parser_setopt( _parser, HUBBUB_PARSER_DOCUMENT_NODE, &params );
	
	_nodes = [NSMutableArray array];
	_quirksMode = HUBBUB_QUIRKS_MODE_NONE;
	
	return self;
}

- (id)init;
{
	return [self initWithCharset: nil];
}

- (void)dealloc;
{
	if (_parser != NULL) {
		hubbub_parser_destroy( _parser );
		_parser = NULL;
	}
}

- (BOOL) parseChunk: (NSData *) chunk;
{
	_lastError = hubbub_parser_parse_chunk( _parser, [chunk bytes], [chunk length] );
	return _lastError == HUBBUB_OK;
}

- (BOOL) parseCompleted;
{
	_lastError = hubbub_parser_completed( _parser );
	self.nodes = nil;
	return _lastError == HUBBUB_OK;
}

+ (NSXMLDocument *)parseDocument: (NSData *)data;
{
	HubbubHtmlParser *parser = [[HubbubHtmlParser alloc] init];
	if (![parser parseChunk: data]) {
		NSLog( @"error parsing data..." );
		return nil;
	}
	[parser parseCompleted];
	return parser.document;
}

static inline NSString *to_nsstring( const hubbub_string *str )
{
	return [[NSString alloc] initWithBytes: str->ptr length: str->len encoding: NSUTF8StringEncoding];
}

static inline void *REF( void *ctx, NSXMLNode *node )
{
	NSCParameterAssert( [node isKindOfClass: [NSXMLNode class]] );
	
	HubbubHtmlParser *parser = (__bridge  HubbubHtmlParser *)ctx;
	[parser.nodes addObject: node];
	return (__bridge void *)node;
}

static hubbub_error create_comment(void *ctx, const hubbub_string *data, 
								   void **result)
{
	NSXMLNode *comment = [NSXMLNode commentWithStringValue: to_nsstring( data )];
	*result = REF( ctx, comment );
	return HUBBUB_OK;
}

static hubbub_error create_doctype(void *ctx, const hubbub_doctype *doctype, void **result)
{
	NSXMLDTD *dtd = [[NSXMLDTD alloc] initWithKind: NSXMLDTDKind];
	[dtd setName: to_nsstring( &doctype->name )];
	
	if (!doctype->system_missing) {
		[dtd setSystemID: to_nsstring( &doctype->system_id )];
	}
	
	if (!doctype->public_missing) {
		[dtd setPublicID: to_nsstring( &doctype->public_id )];
	}
	
	*result = REF( ctx, dtd );
	
	return HUBBUB_OK;
}


static hubbub_error create_element(void *ctx, const hubbub_tag *tag, void **result)
{
	NSXMLElement *element = [NSXMLElement elementWithName: to_nsstring( &tag->name )];
	
	for (uint32_t i = 0; i < tag->n_attributes; i++) {
		hubbub_attribute *attribute = &tag->attributes[i];
		[element addAttribute: [NSXMLNode attributeWithName: to_nsstring( &attribute->name ) stringValue: to_nsstring( &attribute->value )]];
	}
	
	*result = REF( ctx, element );
	
	return HUBBUB_OK;
}

static hubbub_error create_text( void *ctx, const hubbub_string *data, void **result )
{
	NSXMLNode *text = [NSXMLNode textWithStringValue: to_nsstring( data )];
	*result = REF( ctx, text );
	return HUBBUB_OK;
}

static hubbub_error ref_node( void *ctx, void *node )
{
	return HUBBUB_OK;
}

static hubbub_error unref_node( void *ctx, void *node )
{
	return HUBBUB_OK;
}

static hubbub_error append_child( void *ctx, void *parent, void *child, void **result )
{
	if (parent == NULL || child == NULL) {
		return HUBBUB_OK;
	}
	
	NSXMLElement *p = (__bridge  NSXMLElement *)parent;
	NSXMLNode *c = (__bridge  NSXMLNode *)child;
	
	if ([p isKindOfClass: [NSXMLDocument class]] && [c isKindOfClass: [NSXMLDTD class]]) {
		[(NSXMLDocument *)p setDTD: (NSXMLDTD *)c];
	} else {
		[p addChild: c];
	}
	
	*result = (__bridge void *)c;
	
	return HUBBUB_OK;
}

static hubbub_error insert_before( void *ctx, void *parent, void *child, void *ref_child, void **result )
{
	NSXMLElement *p = (__bridge NSXMLElement *)parent;
	NSXMLNode *c = (__bridge  NSXMLNode *)child;
	NSXMLNode *ref = (__bridge  NSXMLNode *)ref_child;
	
	NSUInteger index = [p.children indexOfObject: ref];
	NSCParameterAssert( index != NSNotFound );
	
	[p insertChild: c atIndex: index];
	
	*result = (__bridge  void *)c;
	
	return HUBBUB_OK;
}

static hubbub_error remove_child( void *ctx, void *parent, void *child, void **result )
{
	NSXMLElement *p = (__bridge NSXMLElement *)parent;
	NSXMLNode *c = (__bridge NSXMLNode *)child;
	
	NSUInteger index = [[p children] indexOfObject: c];
	NSCParameterAssert( index != NSNotFound );
	
	[p removeChildAtIndex: index];
	
	*result = child;
	
	return HUBBUB_OK;
}

static hubbub_error clone_node( void *ctx, void *node, bool deep, void **result )
{
	NSXMLNode *n = (__bridge NSXMLNode *)node;
	NSXMLNode *r = [n copy];

	if (!deep && [r isKindOfClass: [NSXMLElement class]]) {
		[(NSXMLElement *)r setChildren: nil];
	}

	*result = REF( ctx, r );
	
	return HUBBUB_OK;
}

static hubbub_error reparent_children( void *ctx, void *node, void *new_parent )
{
	NSXMLElement *n = (__bridge NSXMLElement *)node;
	NSXMLElement *new = (__bridge  NSXMLElement *)new_parent;
	
	for (NSXMLNode *node in [[n children] copy]) {
		[node detach];
		[new addChild: node];
	}
	
	[n setChildren: nil];
	
	return HUBBUB_OK;
}

static hubbub_error get_parent( void *ctx, void *node, bool element_only, void **result )
{
	NSXMLNode *n = (__bridge NSXMLNode *)node;
	NSXMLNode *parent = [n parent];

	if (element_only && [parent kind] != NSXMLElementKind) {
		*result = NULL;
	} else {
		*result = (__bridge  void *)parent;
	}
	
	return HUBBUB_OK;
}

static hubbub_error has_children( void *ctx, void *node, bool *result )
{
	NSXMLElement *element = (__bridge NSXMLElement *)node;
	*result = [element childCount] != 0;
	
	return HUBBUB_OK;
}

static hubbub_error form_associate( void *ctx, void *form, void *node )
{
	return HUBBUB_OK;
}

static hubbub_error add_attributes( void *ctx, void *node, const hubbub_attribute *attributes, uint32_t n_attributes )
{
	NSXMLElement *element = (__bridge NSXMLElement *)node;
	for (uint32_t i = 0; i < n_attributes; i++) {
		const hubbub_attribute *attribute = &attributes[i];
		[element addAttribute: [NSXMLNode attributeWithName: to_nsstring( &attribute->name ) stringValue: to_nsstring( &attribute->value )]];
	}
	
	return HUBBUB_OK;
}

static hubbub_error set_quirks_mode( void *ctx, hubbub_quirks_mode mode )
{
	HubbubHtmlParser *parser = (__bridge HubbubHtmlParser *)ctx;
	parser->_quirksMode = mode;
	return HUBBUB_OK;
}

static hubbub_error change_encoding( void *ctx, const char *charset )
{
	NSLog( @"%s: %s", __FUNCTION__, charset );
	return HUBBUB_OK;
}

static void *mem_realloc(void *ptr, size_t len, void *pw)
{
	if (len == 0) {
		free( ptr );
		return NULL;
	} else {
		return realloc(ptr, len);
	}
}

@end
