#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <Python/Python.h>
#include <math.h>

static BOOL finiteNumber(id value) { return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]); }
static BOOL color(CGContextRef context, id value, BOOL fill) {
    if (![value isKindOfClass:NSArray.class] || ([value count] != 3 && [value count] != 4)) return NO;
    for (id part in value) if (!finiteNumber(part) || [part doubleValue] < 0 || [part doubleValue] > 1) return NO;
    CGFloat r = [value[0] doubleValue], g = [value[1] doubleValue], b = [value[2] doubleValue];
    CGFloat a = [value count] == 4 ? [value[3] doubleValue] : 1;
    if (fill) CGContextSetRGBFillColor(context, r, g, b, a); else CGContextSetRGBStrokeColor(context, r, g, b, a);
    return YES;
}

static BOOL draw(CGContextRef context, NSArray *commands, NSString **problem) {
    for (id value in commands) {
        if (![value isKindOfClass:NSDictionary.class]) { *problem = @"Each drawing command must be an object"; return NO; }
        NSDictionary *command = value;
        NSString *kind = command[@"type"];
        if (![kind isKindOfClass:NSString.class]) { *problem = @"Drawing command requires type"; return NO; }
        if (!color(context, command[@"color"] ?: @[@0,@0,@0], NO) || !color(context, command[@"color"] ?: @[@0,@0,@0], YES)) {
            *problem = @"Color must contain 3 or 4 numbers between 0 and 1"; return NO;
        }
        if (command[@"line_width"] && !finiteNumber(command[@"line_width"])) { *problem = @"Invalid line width"; return NO; }
        double lineWidth = command[@"line_width"] ? [command[@"line_width"] doubleValue] : 1;
        if (!isfinite(lineWidth) || lineWidth < 0) { *problem = @"Invalid line width"; return NO; }
        CGContextSetLineWidth(context, lineWidth);
        if ([kind isEqual:@"line"] || [kind isEqual:@"polyline"]) {
            NSArray *points = command[@"points"];
            if (![points isKindOfClass:NSArray.class] || points.count < 2) { *problem = @"A line requires at least two points"; return NO; }
            CGContextBeginPath(context);
            for (NSUInteger index = 0; index < points.count; index++) {
                id point = points[index];
                if (![point isKindOfClass:NSArray.class] || [point count] != 2 || !finiteNumber(point[0]) || !finiteNumber(point[1])) { *problem = @"Invalid point"; return NO; }
                if (index == 0) CGContextMoveToPoint(context, [point[0] doubleValue], [point[1] doubleValue]);
                else CGContextAddLineToPoint(context, [point[0] doubleValue], [point[1] doubleValue]);
            }
            CGContextStrokePath(context);
        } else {
            if (!finiteNumber(command[@"x"]) || !finiteNumber(command[@"y"])) { *problem = @"Coordinates must be finite numbers"; return NO; }
            double x = [command[@"x"] doubleValue], y = [command[@"y"] doubleValue];
            if ([kind isEqual:@"text"]) {
                NSString *text = command[@"text"];
                id size = command[@"size"] ?: @12;
                if (![text isKindOfClass:NSString.class] || !finiteNumber(size) || [size doubleValue] <= 0) { *problem = @"Invalid text or font size"; return NO; }
                CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), [size doubleValue], NULL);
                NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:@{(__bridge id)kCTFontAttributeName:(__bridge id)font, (__bridge id)kCTForegroundColorFromContextAttributeName:@YES}];
                CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
                CGContextSaveGState(context);
                CGContextTranslateCTM(context, x, y + CTFontGetAscent(font));
                CGContextScaleCTM(context, 1, -1);
                CGContextSetTextMatrix(context, CGAffineTransformIdentity);
                CGContextSetTextPosition(context, 0, 0);
                CTLineDraw(line, context);
                CGContextRestoreGState(context);
                CFRelease(line); CFRelease(font);
            } else {
                if (!finiteNumber(command[@"width"]) || !finiteNumber(command[@"height"])) { *problem = @"Dimensions must be finite numbers"; return NO; }
                CGRect rect = CGRectMake(x, y, [command[@"width"] doubleValue], [command[@"height"] doubleValue]);
                if (rect.size.width < 0 || rect.size.height < 0) { *problem = @"Dimensions must be nonnegative"; return NO; }
                if ([kind isEqual:@"rect"] || [kind isEqual:@"ellipse"]) {
                    if (command[@"fill"] && ![command[@"fill"] isKindOfClass:NSNumber.class]) { *problem = @"Fill must be a boolean"; return NO; }
                    BOOL fill = [command[@"fill"] boolValue];
                    if ([kind isEqual:@"rect"]) { if (fill) CGContextFillRect(context, rect); else CGContextStrokeRect(context, rect); }
                    else { if (fill) CGContextFillEllipseInRect(context, rect); else CGContextStrokeEllipseInRect(context, rect); }
                } else if ([kind isEqual:@"image"]) {
                    NSString *path = command[@"path"];
                    if (![path isKindOfClass:NSString.class]) { *problem = @"Image requires a local path"; return NO; }
                    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
                    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
                    if (!image) { if (source) CFRelease(source); *problem = @"Cannot decode image"; return NO; }
                    CGContextSaveGState(context);
                    CGContextTranslateCTM(context, rect.origin.x, rect.origin.y + rect.size.height);
                    CGContextScaleCTM(context, 1, -1);
                    CGContextDrawImage(context, CGRectMake(0, 0, rect.size.width, rect.size.height), image);
                    CGContextRestoreGState(context);
                    CGImageRelease(image); CFRelease(source);
                } else { *problem = [@"Unknown drawing command: " stringByAppendingString:kind]; return NO; }
            }
        }
    }
    return YES;
}

static PyObject *render(PyObject *module, PyObject *args) {
    const char *json, *filename;
    if (!PyArg_ParseTuple(args, "ss", &json, &filename)) return NULL;
    @autoreleasepool {
        NSError *error = nil;
        id input = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
        NSString *path = [NSString stringWithUTF8String:filename];
        if (![input isKindOfClass:NSDictionary.class] || !finiteNumber(input[@"width"]) || !finiteNumber(input[@"height"]) || ![input[@"commands"] isKindOfClass:NSArray.class]) {
            PyErr_SetString(PyExc_ValueError, "Canvas requires width, height and commands"); return NULL;
        }
        double width = [input[@"width"] doubleValue], height = [input[@"height"] doubleValue];
        if (width < 1 || height < 1 || width > 16384 || height > 16384 || width * height > 16777216) {
            PyErr_SetString(PyExc_ValueError, "Canvas is too large or has invalid dimensions"); return NULL;
        }
        BOOL pdf = [path.pathExtension.lowercaseString isEqual:@"pdf"];
        if (!pdf && ![path.pathExtension.lowercaseString isEqual:@"png"]) { PyErr_SetString(PyExc_ValueError, "Output must be .pdf or .png"); return NULL; }
        NSMutableData *data = [NSMutableData data];
        CGContextRef context;
        CGDataConsumerRef consumer = NULL;
        if (pdf) {
            CGRect page = CGRectMake(0, 0, width, height);
            consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
            context = CGPDFContextCreate(consumer, &page, NULL);
            if (context) CGPDFContextBeginPage(context, NULL);
        } else {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            context = CGBitmapContextCreate(NULL, (size_t)ceil(width), (size_t)ceil(height), 8, 0, space, kCGImageAlphaPremultipliedLast);
            CGColorSpaceRelease(space);
        }
        if (!context) { if (consumer) CGDataConsumerRelease(consumer); return PyErr_NoMemory(); }
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        NSString *problem = nil;
        BOOL success = draw(context, input[@"commands"], &problem);
        if (pdf) { CGPDFContextEndPage(context); CGPDFContextClose(context); CGDataConsumerRelease(consumer); }
        else if (success) {
            CGImageRef image = CGBitmapContextCreateImage(context);
            CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
            if (image && output) { CGImageDestinationAddImage(output, image, NULL); success = CGImageDestinationFinalize(output); }
            else success = NO;
            if (output) CFRelease(output);
            if (image) CGImageRelease(image);
        }
        CGContextRelease(context);
        if (success) success = [data writeToFile:path options:NSDataWritingAtomic error:&error];
        if (!success) { PyErr_SetString(PyExc_RuntimeError, (problem ?: error.localizedDescription ?: @"Cannot render canvas").UTF8String); return NULL; }
        Py_RETURN_NONE;
    }
}
static PyMethodDef methods[] = {{"render", render, METH_VARARGS, "Render a canvas to PNG or PDF using CoreGraphics."}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef definition = {PyModuleDef_HEAD_INIT, "_hyotan_graphics", NULL, -1, methods};
PyObject *PyInit__hyotan_graphics(void) { return PyModule_Create(&definition); }
