/* WebROaR - Ruby Application Server - http://webroar.in/
 * Copyright (C) 2009  Goonj LLC
 *
 * This file is part of WebROaR.
 *
 * WebROaR is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * WebROaR is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with WebROaR.  If not, see <http://www.gnu.org/licenses/>.
 */
/******************************************************************************
 *               C Extension to run Unit Test Cases
 *****************************************************************************/

#include <ruby.h>
#include <test.h>

VALUE run()
{
  test_scgi();
  test_yaml_parser();
  test_queue();
  test_util();
}

Init_test_ext()
{
  VALUE mTest;
  VALUE cTest;

  mTest = rb_define_module("Test");
  cTest = rb_define_class_under(mTest, "Test", rb_cObject);
  rb_define_singleton_method(cTest, "run", run, 0);
}
