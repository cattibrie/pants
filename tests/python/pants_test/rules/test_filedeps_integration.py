# coding=utf-8
# Copyright 2018 Pants project contributors (see CONTRIBUTORS.md).
# Licensed under the Apache License, Version 2.0 (see LICENSE).

from __future__ import absolute_import, division, print_function, unicode_literals

from pants_test.pants_run_integration_test import PantsRunIntegrationTest


class FiledepsIntegrationTest(PantsRunIntegrationTest):

  def test_filedeps_one_target(self):
    args = [
      '--no-v1',
      '--v2',
      'filedeps',
      'testprojects/tests/python/pants/dummies:passing_target',
    ]
    pants_run = self.run_pants(args)
    self.assert_success(pants_run)

    self.assertEqual("", pants_run.stderr_data)
    self.assertEqual(pants_run.returncode, 0)

    self.assertEqual(pants_run.stdout_data,
      '''testprojects/tests/python/pants/dummies/BUILD
testprojects/tests/python/pants/dummies/test_pass.py
''')

  def test_filedeps_one_target_with_deps(self):
    args = [
      '--no-v1',
      '--v2',
      'filedeps',
      'examples/src/scala/org/pantsbuild/example/hello/exe:exe',
    ]
    pants_run = self.run_pants(args)
    self.assert_success(pants_run)

    self.assertEqual("", pants_run.stderr_data)
    self.assertEqual(pants_run.returncode, 0)

    self.assertEqual(pants_run.stdout_data,
                      '''examples/src/scala/org/pantsbuild/example/hello/exe/BUILD
examples/src/scala/org/pantsbuild/example/hello/exe/Exe.scala
examples/src/scala/org/pantsbuild/example/hello/welcome/BUILD
examples/src/scala/org/pantsbuild/example/hello/welcome/Welcome.scala
examples/src/java/org/pantsbuild/example/hello/greet/BUILD
examples/src/java/org/pantsbuild/example/hello/greet/Greeting.java
examples/src/resources/org/pantsbuild/example/hello/BUILD
examples/src/resources/org/pantsbuild/example/hello/world.txt
''')

  def test_filedeps_multiple_targets_with_dep(self):
    args = [
      '--no-v1',
      '--v2',
      'filedeps',
      'examples/src/scala/org/pantsbuild/example/hello/exe:exe',
      'examples/src/scala/org/pantsbuild/example/hello/welcome:welcome'
    ]
    pants_run = self.run_pants(args)
    self.assert_success(pants_run)

    self.assertEqual("", pants_run.stderr_data)
    self.assertEqual(pants_run.returncode, 0)

    self.assertEqual(pants_run.stdout_data,
      '''examples/src/scala/org/pantsbuild/example/hello/exe/BUILD
examples/src/scala/org/pantsbuild/example/hello/exe/Exe.scala
examples/src/scala/org/pantsbuild/example/hello/welcome/BUILD
examples/src/scala/org/pantsbuild/example/hello/welcome/Welcome.scala
examples/src/java/org/pantsbuild/example/hello/greet/BUILD
examples/src/java/org/pantsbuild/example/hello/greet/Greeting.java
examples/src/resources/org/pantsbuild/example/hello/BUILD
examples/src/resources/org/pantsbuild/example/hello/world.txt
''')
